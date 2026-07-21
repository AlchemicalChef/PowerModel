defmodule PowerModel.Ingestion.LoadEstimator do
  @moduledoc """
  Creates a **synthetic spatial baseline** of loads — it does NOT use real
  demand data.

  Total load is set to 85% of in-service generation capacity and distributed
  across PQ buses with power factor 0.95 lagging. The spatial weights are
  **population-based** when Census county data is present (`mix
  power_model.ingest population`): each county's population is assigned to
  its nearest PQ bus, and a bus's share of load is 80% its share of national
  population + 20% uniform floor (so empty-county transmission buses keep a
  nonzero load). Without county data it falls back to the old gen-proximity
  heuristic (50% uniform, 50% proportional to bus-attached generation).

  These per-bus values serve as spatial weights: when EIA-930 demand data is
  ingested (`mix power_model.ingest demand`), `PowerModel.Demand.scale_loads/3`
  rescales them at snapshot time so each balancing authority's total matches
  its actual demand for the selected hour.

  Water facility MW (merged into `constant_power` rows by
  `Grid.map_water_facilities_to_grid/1`) is re-applied after re-estimation,
  since re-estimation rebuilds those rows from scratch.
  """

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Grid.{Bus, Generator, Load}

  @power_factor 0.95
  # ~0.3287
  @q_ratio :math.tan(:math.acos(@power_factor))
  @population_weight 0.8

  @doc """
  Create loads at each PQ bus. Total load is set to ~85% of total generation
  capacity (typical reserve margin); distribution is population-weighted when
  Census county data is available.
  """
  def run do
    IO.puts("Estimating loads...")

    # Clear existing estimated loads to avoid duplicates
    {deleted, _} = Repo.delete_all(from l in Load, where: l.load_type == "constant_power")
    if deleted > 0, do: IO.puts("  Cleared #{deleted} existing estimated loads.")

    # Get total in-service generation capacity
    total_gen =
      Repo.one(
        from g in Generator,
          where: g.status == "in_service" and not is_nil(g.bus_id),
          select: sum(g.p_max_mw)
      ) || 0.0

    # Target load = 85% of capacity (15% reserve margin)
    target_load = total_gen * 0.85

    IO.puts("  Total generation capacity: #{Float.round(total_gen, 0)} MW")
    IO.puts("  Target total load (85%): #{Float.round(target_load, 0)} MW")

    pq_buses = Repo.all(from b in Bus, where: b.bus_type == 1)

    if Enum.empty?(pq_buses) do
      IO.puts("  No PQ buses found. Run bus mapping first.")
      {:error, :no_buses}
    else
      pop_by_bus = population_per_bus()
      total_pop = pop_by_bus |> Map.values() |> Enum.sum()

      weight_fn =
        if total_pop > 0 do
          IO.puts(
            "  Population weighting: #{map_size(pop_by_bus)} buses carry #{total_pop} people."
          )

          population_weights(pq_buses, pop_by_bus, total_pop)
        else
          IO.puts("  No county population data; falling back to gen-proximity weighting.")
          IO.puts("  (Run `mix power_model.ingest population data/` for population-based loads.)")
          gen_proximity_weights(pq_buses, total_gen)
        end

      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      loads =
        Enum.map(pq_buses, fn bus ->
          p_mw = max(weight_fn.(bus) * target_load, 1.0)
          q_mvar = p_mw * @q_ratio

          %{
            bus_id: bus.id,
            p_mw: Float.round(p_mw, 2),
            q_mvar: Float.round(q_mvar, 2),
            load_type: "constant_power",
            status: "in_service",
            inserted_at: now,
            updated_at: now
          }
        end)

      # Batch insert (replace on conflict with bus_id)
      loads
      |> Enum.chunk_every(500)
      |> Enum.each(fn batch ->
        Repo.insert_all(Load, batch,
          on_conflict: {:replace, [:p_mw, :q_mvar, :updated_at]},
          conflict_target: [:bus_id, :load_type]
        )
      end)

      actual_total = Enum.sum(Enum.map(loads, & &1.p_mw))
      IO.puts("  Created #{length(loads)} loads, total: #{Float.round(actual_total, 0)} MW")

      # Re-estimation rebuilt the constant_power rows, dropping the water
      # facility MW that map_water_facilities_to_grid had merged in.
      {updated, inserted} = PowerModel.Grid.reapply_water_facility_loads()

      if updated + inserted > 0 do
        IO.puts("  Re-applied water facility MW (#{updated} loads updated, #{inserted} created).")
      end

      {:ok, length(loads)}
    end
  end

  # Bus weight = 80% population share + 20% uniform floor.
  defp population_weights(pq_buses, pop_by_bus, total_pop) do
    uniform = (1.0 - @population_weight) / length(pq_buses)

    fn bus ->
      pop_share = Map.get(pop_by_bus, bus.id, 0) / total_pop
      @population_weight * pop_share + uniform
    end
  end

  # Legacy heuristic: 50% uniform + 50% proportional to bus-attached generation.
  defp gen_proximity_weights(pq_buses, total_gen) do
    gen_per_bus =
      Repo.all(
        from g in Generator,
          where: g.status == "in_service" and not is_nil(g.bus_id),
          group_by: g.bus_id,
          select: {g.bus_id, sum(g.p_max_mw)}
      )
      |> Map.new()

    uniform = 0.5 / length(pq_buses)

    fn bus ->
      if total_gen > 0 do
        uniform + 0.5 * Map.get(gen_per_bus, bus.id, 0.0) / total_gen
      else
        1.0 / length(pq_buses)
      end
    end
  end

  # Each county's population is split across its nearest PQ buses (up to 25
  # within 75 km, inverse-distance weighted; always at least the single
  # nearest bus, however far). Splitting matters: dumping a 9.7M-person
  # county on one bus puts tens of GW behind a handful of lines and breaks
  # power flow. KNN rides the buses GIST index via a LATERAL join.
  defp population_per_bus do
    %{rows: rows} =
      Repo.query!("""
      WITH nearest AS (
        SELECT c.id AS county_id, c.population, n.id AS bus_id, n.dist_m,
               ROW_NUMBER() OVER (PARTITION BY c.id ORDER BY n.dist_m) AS rn
        FROM county_population c
        JOIN LATERAL (
          SELECT b.id,
                 ST_Distance(b.coordinates::geography, c.coordinates::geography) AS dist_m
          FROM buses b
          WHERE b.bus_type = 1 AND b.coordinates IS NOT NULL
          ORDER BY b.coordinates <-> c.coordinates
          LIMIT 25
        ) n ON true
      ),
      kept AS (
        SELECT * FROM nearest WHERE rn = 1 OR dist_m <= 75000
      ),
      weighted AS (
        SELECT bus_id,
               population * (1.0 / GREATEST(dist_m, 1000))
                 / SUM(1.0 / GREATEST(dist_m, 1000)) OVER (PARTITION BY county_id) AS pop
        FROM kept
      )
      SELECT bus_id, SUM(pop)::float FROM weighted GROUP BY bus_id
      """)

    Map.new(rows, fn [bus_id, pop] -> {bus_id, pop} end)
  end
end
