defmodule PowerModel.Solver.EconomicDispatch do
  @moduledoc """
  Merit-order economic dispatch.
  Stacks generators by marginal cost (cheapest first), dispatches to meet load.
  Respects p_min/p_max constraints and ramp rate limits.
  """

  # Default ramp rate as fraction of p_max per minute, by fuel type
  @ramp_rate_mult %{
    "NUC" => 0.01,
    "COL" => 0.02,
    "NG" => 0.08,
    "WAT" => 0.5,
    "WND" => 1.0,
    "SUN" => 1.0,
    "PET" => 0.03,
    "GEO" => 0.01,
    "BIT" => 0.02,
    "SUB" => 0.02,
    "LIG" => 0.02,
    "OG" => 0.05,
    "DFO" => 0.05,
    "RFO" => 0.03,
    "WH" => 0.5
  }

  @doc """
  Dispatch generators to meet total_load_mw.
  Returns %{gen_id => dispatch_mw} map.

  Generators are sorted by marginal_cost_per_mwh (cheapest first).
  Each generator dispatches between p_min and p_max.
  Wind/Solar dispatch at capacity_factor * p_max (must-take).
  """
  def dispatch(generators, total_load_mw) do
    {must_take, dispatchable} =
      Enum.split_with(generators, fn g ->
        (Map.get(g, :marginal_cost_per_mwh) || 999.0) <= 0.01
      end)

    must_take_dispatch =
      Map.new(must_take, fn g ->
        cf = Map.get(g, :capacity_factor) || 0.3
        {g.id, g.p_max_mw * cf}
      end)

    must_take_total = must_take_dispatch |> Map.values() |> Enum.sum()
    remaining_load = max(total_load_mw - must_take_total, 0.0)

    sorted = Enum.sort_by(dispatchable, fn g -> Map.get(g, :marginal_cost_per_mwh) || 999.0 end)

    total_p_min = Enum.sum(Enum.map(sorted, fn g -> Map.get(g, :p_min_mw) || 0.0 end))
    load_above_min = max(remaining_load - total_p_min, 0.0)

    {dispatch_map, _remaining} =
      Enum.reduce(sorted, {%{}, load_above_min}, fn g, {acc, rem} ->
        p_min = Map.get(g, :p_min_mw) || 0.0
        p_max = g.p_max_mw || 0.0
        headroom = max(p_max - p_min, 0.0)
        above_min = min(headroom, max(rem, 0.0))
        dispatch = p_min + above_min
        {Map.put(acc, g.id, dispatch), rem - above_min}
      end)

    Map.merge(must_take_dispatch, dispatch_map)
  end

  @doc """
  Redispatch after a contingency (generator trip or load change).
  Takes current dispatch, removes tripped generators, and redistributes
  the deficit using merit order among remaining generators with headroom.

  The optional `time_window_min` parameter constrains each generator's
  pickup to `ramp_rate_mw_per_min * time_window_min`. Pass `:infinity`
  (or omit) for unconstrained redispatch.

  Returns {new_dispatch_map, unmet_deficit_mw}.
  """
  def redispatch(
        current_dispatch,
        generators,
        tripped_gen_ids,
        deficit_mw,
        time_window_min \\ :infinity
      ) do
    online =
      generators
      |> Enum.reject(fn g -> MapSet.member?(tripped_gen_ids, g.id) end)
      |> Enum.sort_by(fn g -> Map.get(g, :marginal_cost_per_mwh) || 999.0 end)

    {new_dispatch, remaining} =
      Enum.reduce(online, {current_dispatch, deficit_mw}, fn g, {acc, rem} ->
        if rem <= 0.0 do
          {acc, rem}
        else
          current = Map.get(acc, g.id, 0.0)
          headroom = max((g.p_max_mw || 0.0) - current, 0.0)

          ramp_limit =
            case time_window_min do
              :infinity ->
                headroom

              tw when is_number(tw) and tw > 0 ->
                ramp_rate = Map.get(g, :ramp_rate_mw_per_min) || default_ramp_rate(g)
                ramp_rate * tw

              _ ->
                headroom
            end

          increase = min(headroom, min(ramp_limit, rem))
          {Map.put(acc, g.id, current + increase), rem - increase}
        end
      end)

    new_dispatch = Map.drop(new_dispatch, MapSet.to_list(tripped_gen_ids))

    {new_dispatch, remaining}
  end

  defp default_ramp_rate(g) do
    fuel = Map.get(g, :fuel_type) || ""
    mult = Map.get(@ramp_rate_mult, fuel, 0.03)
    (g.p_max_mw || 0.0) * mult
  end
end
