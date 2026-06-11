defmodule PowerModel.Ingestion.LoadEstimator do
  @moduledoc """
  Estimates load distribution across buses.

  Uses EIA total demand data per interconnection and distributes load
  proportionally across PQ buses, with power factor 0.95 lagging.
  """

  require Logger

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Grid.{Bus, Generator, Load}

  @power_factor 0.95
  @q_ratio :math.tan(:math.acos(@power_factor))

  @doc """
  Create loads at each PQ bus, sized proportionally to connected generation.
  Total load is set to ~85% of total generation capacity (typical reserve margin).
  """
  def run do
    Logger.info("Estimating loads...")

    {deleted, _} = Repo.delete_all(from l in Load, where: l.load_type == "constant_power")
    if deleted > 0, do: Logger.info("  Cleared #{deleted} existing estimated loads.")

    total_gen =
      Repo.one(
        from g in Generator,
          where: g.status == "in_service" and not is_nil(g.bus_id),
          select: sum(g.p_max_mw)
      ) || 0.0

    target_load = total_gen * 0.85

    Logger.info("  Total generation capacity: #{Float.round(total_gen, 0)} MW")
    Logger.info("  Target total load (85%): #{Float.round(target_load, 0)} MW")

    pq_buses = Repo.all(from b in Bus, where: b.bus_type == 1)

    if Enum.empty?(pq_buses) do
      Logger.info("  No PQ buses found. Run bus mapping first.")
      {:error, :no_buses}
    else
      gen_per_bus =
        Repo.all(
          from g in Generator,
            where: g.status == "in_service" and not is_nil(g.bus_id),
            group_by: g.bus_id,
            select: {g.bus_id, sum(g.p_max_mw)}
        )
        |> Map.new()

      base_load_per_bus = target_load / length(pq_buses)

      loads =
        Enum.map(pq_buses, fn bus ->
          gen_mw = Map.get(gen_per_bus, bus.id, 0.0)

          p_mw =
            if total_gen > 0 do
              uniform = base_load_per_bus * 0.5
              proportional = gen_mw / total_gen * target_load * 0.5
              uniform + proportional
            else
              base_load_per_bus
            end

          p_mw = max(p_mw, 1.0)
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

      loads
      |> Enum.chunk_every(500)
      |> Enum.each(fn batch ->
        Repo.insert_all(Load, batch,
          on_conflict: {:replace, [:p_mw, :q_mvar, :updated_at]},
          conflict_target: [:bus_id]
        )
      end)

      actual_total = Enum.sum(Enum.map(loads, & &1.p_mw))
      Logger.info("  Created #{length(loads)} loads, total: #{Float.round(actual_total, 0)} MW")
      {:ok, length(loads)}
    end
  end
end
