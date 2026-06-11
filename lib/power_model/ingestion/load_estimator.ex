defmodule PowerModel.Ingestion.LoadEstimator do
  @moduledoc """
  Creates a **synthetic spatial baseline** of loads — it does NOT use real
  demand data.

  Total load is set to 85% of in-service generation capacity and distributed
  across PQ buses (50% uniform, 50% proportional to bus-attached generation),
  with power factor 0.95 lagging. These per-bus values serve as spatial
  weights: when EIA-930 demand data is ingested (`mix power_model.ingest
  demand`), `PowerModel.Demand.scale_loads/3` rescales them at snapshot time
  so each balancing authority's total matches its actual demand for the
  selected hour. Without EIA-930 data, the baseline is used as-is.
  """

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Grid.{Bus, Generator, Load}

  @power_factor 0.95
  @q_ratio :math.tan(:math.acos(@power_factor))  # ~0.3287

  @doc """
  Create loads at each PQ bus, sized proportionally to connected generation.
  Total load is set to ~85% of total generation capacity (typical reserve margin).
  """
  def run do
    IO.puts("Estimating loads...")

    # Clear existing estimated loads to avoid duplicates
    {deleted, _} = Repo.delete_all(from l in Load, where: l.load_type == "constant_power")
    if deleted > 0, do: IO.puts("  Cleared #{deleted} existing estimated loads.")

    # Get total in-service generation capacity
    total_gen = Repo.one(
      from g in Generator,
        where: g.status == "in_service" and not is_nil(g.bus_id),
        select: sum(g.p_max_mw)
    ) || 0.0

    # Target load = 85% of capacity (15% reserve margin)
    target_load = total_gen * 0.85

    IO.puts("  Total generation capacity: #{Float.round(total_gen, 0)} MW")
    IO.puts("  Target total load (85%): #{Float.round(target_load, 0)} MW")

    # Get all PQ buses (bus_type = 1) that have generation nearby
    # Distribute load to all PQ buses
    pq_buses = Repo.all(from b in Bus, where: b.bus_type == 1)

    if Enum.empty?(pq_buses) do
      IO.puts("  No PQ buses found. Run bus mapping first.")
      {:error, :no_buses}
    else
      # Get generation per bus
      gen_per_bus = Repo.all(
        from g in Generator,
          where: g.status == "in_service" and not is_nil(g.bus_id),
          group_by: g.bus_id,
          select: {g.bus_id, sum(g.p_max_mw)}
      ) |> Map.new()

      # Each PQ bus gets load proportional to nearby generation
      # Buses without direct generation get a base load
      base_load_per_bus = target_load / length(pq_buses)

      loads = Enum.map(pq_buses, fn bus ->
        gen_mw = Map.get(gen_per_bus, bus.id, 0.0)

        # Weighted: 50% uniform + 50% proportional to gen
        p_mw = if total_gen > 0 do
          uniform = base_load_per_bus * 0.5
          proportional = (gen_mw / total_gen) * target_load * 0.5
          uniform + proportional
        else
          base_load_per_bus
        end

        p_mw = max(p_mw, 1.0)  # minimum 1 MW
        q_mvar = p_mw * @q_ratio

        now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

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
      {:ok, length(loads)}
    end
  end
end
