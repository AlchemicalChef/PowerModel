defmodule PowerModel.Solver.UnitCommitment do
  @moduledoc """
  Simple merit-order unit commitment.

  Determines which generators are online before cascade simulation begins.
  Must-run units (nuclear, renewables, hydro baseload) are always committed.
  Dispatchable units are committed cheapest-first until total committed
  capacity reaches `total_load * reserve_margin`.
  """

  @default_reserve_margin 1.15

  @must_run_fuels MapSet.new(~w(NUC WAT WH GEO WND SUN))

  @doc """
  Commit generators to meet load with reserve margin.

  Returns `{online_generators, offline_generator_ids}` where
  `offline_generator_ids` is a MapSet of IDs not committed.
  """
  def commit(generators, total_load_mw, opts \\ []) do
    reserve_margin = Keyword.get(opts, :reserve_margin, @default_reserve_margin)
    target_capacity = total_load_mw * reserve_margin

    in_service =
      Enum.filter(generators, fn g ->
        Map.get(g, :status, "in_service") == "in_service"
      end)

    {must_run, dispatchable} =
      Enum.split_with(in_service, fn g ->
        fuel = Map.get(g, :fuel_type) || ""
        MapSet.member?(@must_run_fuels, fuel)
      end)

    must_run_capacity = Enum.sum(Enum.map(must_run, fn g -> g.p_max_mw || 0.0 end))

    remaining_target = max(target_capacity - must_run_capacity, 0.0)

    sorted =
      Enum.sort_by(dispatchable, fn g ->
        Map.get(g, :marginal_cost_per_mwh) || 999.0
      end)

    {committed_dispatchable, _cap} =
      Enum.reduce(sorted, {[], 0.0}, fn g, {acc, cap} ->
        if cap >= remaining_target do
          {acc, cap}
        else
          {[g | acc], cap + (g.p_max_mw || 0.0)}
        end
      end)

    online = must_run ++ committed_dispatchable
    online_ids = MapSet.new(online, & &1.id)

    offline_ids =
      generators
      |> Enum.reject(fn g -> MapSet.member?(online_ids, g.id) end)
      |> MapSet.new(& &1.id)

    {online, offline_ids}
  end
end
