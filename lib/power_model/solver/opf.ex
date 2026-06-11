defmodule PowerModel.Solver.OPF do
  @moduledoc """
  DC Optimal Power Flow (DCOPF).

  Minimizes total generation cost subject to:
  - Power balance at each bus (DC power flow equations)
  - Generator output limits (p_min ≤ p_g ≤ p_max)
  - Line flow limits (|f_l| ≤ rating_l)

  The DC OPF is a linear program:

      min   sum(c_g * p_g)
      s.t.  B' * theta = P_gen - P_load    (DC power flow)
            p_min_g ≤ p_g ≤ p_max_g         (generator limits)
            |b_l * (theta_i - theta_j)| ≤ f_max_l  (line flow limits)

  This is solved via an iterative penalty method:
  1. Start with unconstrained economic dispatch
  2. Solve DC power flow
  3. For lines exceeding limits, add generation shift to relieve congestion
  4. Iterate until all lines are within limits

  ## Results
  - Dispatch: %{gen_id => p_mw}
  - LMPs: %{bus_id => $/MWh} (Locational Marginal Prices)
  - Congested lines: [{line_id, flow_mw, limit_mw, shadow_price}]
  """

  alias PowerModel.Solver.{DCPowerFlow, EconomicDispatch, Sparse}

  defstruct [
    # %{gen_id => p_mw}
    :dispatch,
    # %{bus_id => $/MWh}
    :lmps,
    # [%{line_id, flow_mw, limit_mw, shadow_price}]
    :congested_lines,
    # $/hr
    :total_cost,
    :converged,
    :iterations
  ]

  @max_iterations 20
  # Allow 2% over rating before re-dispatching
  @congestion_tolerance 1.02

  @doc """
  Solve DC Optimal Power Flow.

  ## Options
    * `:base_mva` — system MVA base (default 100.0)
    * `:max_iterations` — max OPF iterations (default 20)
    * `:include_lmps` — compute LMPs (default true)
  """
  def solve(snapshot, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)
    max_iter = Keyword.get(opts, :max_iterations, @max_iterations)

    total_load = Enum.sum_by(snapshot.loads, & &1.p_mw)

    # Start with unconstrained economic dispatch
    dispatch = EconomicDispatch.dispatch(snapshot.generators, total_load)

    # Iterative re-dispatch to relieve congestion
    {final_dispatch, congested, converged, iterations} =
      iterate_opf(snapshot, dispatch, base_mva, max_iter, 0)

    # Compute total cost
    gen_cost_map =
      Map.new(snapshot.generators, fn g ->
        {g.id, Map.get(g, :marginal_cost_per_mwh) || 40.0}
      end)

    total_cost =
      Enum.reduce(final_dispatch, 0.0, fn {gen_id, p_mw}, acc ->
        cost = Map.get(gen_cost_map, gen_id, 40.0)
        acc + cost * p_mw
      end)

    # Compute LMPs from the final power flow solution
    lmps = compute_lmps(snapshot, final_dispatch, congested, base_mva)

    %__MODULE__{
      dispatch: final_dispatch,
      lmps: lmps,
      congested_lines: congested,
      total_cost: Float.round(total_cost, 2),
      converged: converged,
      iterations: iterations
    }
  end

  @doc """
  Find the most congested lines in the current dispatch.
  """
  def find_congestion(snapshot, dispatch, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)

    # Apply dispatch to generators
    dispatched_gens =
      Enum.map(snapshot.generators, fn g ->
        d = Map.get(dispatch, g.id, 0.0)
        %{g | p_max_mw: d, capacity_factor: 1.0}
      end)

    pf_snapshot = %{snapshot | generators: dispatched_gens}

    try do
      solution = DCPowerFlow.solve(pf_snapshot, base_mva: base_mva)

      solution.line_flows
      |> Enum.filter(fn {_key, flow} -> flow.loading_pct > 100.0 end)
      |> Enum.map(fn {{type, id}, flow} ->
        %{
          type: type,
          line_id: id,
          flow_mw: abs(flow.p_flow_mw),
          loading_pct: flow.loading_pct,
          from_bus_id: flow.from_bus_id,
          to_bus_id: flow.to_bus_id
        }
      end)
      |> Enum.sort_by(fn c -> -c.loading_pct end)
    catch
      _, _ -> []
    end
  end

  # Iterative OPF: re-dispatch to relieve congestion
  defp iterate_opf(snapshot, dispatch, base_mva, max_iter, iter, shadow_prices \\ %{})

  defp iterate_opf(_snapshot, dispatch, _base_mva, max_iter, iter, _shadow_prices)
       when iter >= max_iter do
    {dispatch, [], false, iter}
  end

  defp iterate_opf(snapshot, dispatch, base_mva, max_iter, iter, shadow_prices) do
    # Apply dispatch and solve power flow
    dispatched_gens =
      Enum.map(snapshot.generators, fn g ->
        d = Map.get(dispatch, g.id, 0.0)
        %{g | p_max_mw: d, capacity_factor: 1.0}
      end)

    pf_snapshot = %{snapshot | generators: dispatched_gens}

    try do
      solution = DCPowerFlow.solve(pf_snapshot, base_mva: base_mva)

      # Find overloaded lines
      overloaded =
        solution.line_flows
        |> Enum.filter(fn {_key, flow} ->
          flow.loading_pct > 100.0 * @congestion_tolerance
        end)
        |> Enum.sort_by(fn {_key, flow} -> -flow.loading_pct end)

      if Enum.empty?(overloaded) do
        # All lines within limits — converged
        congested =
          solution.line_flows
          |> Enum.filter(fn {_key, flow} -> flow.loading_pct > 90.0 end)
          |> Enum.map(fn {{type, id}, flow} ->
            sp = Map.get(shadow_prices, {type, id}, 0.0)

            %{
              type: type,
              line_id: id,
              flow_mw: abs(flow.p_flow_mw),
              loading_pct: flow.loading_pct,
              shadow_price: sp,
              from_bus_id: flow.from_bus_id,
              to_bus_id: flow.to_bus_id
            }
          end)

        {dispatch, congested, true, iter + 1}
      else
        # Re-dispatch to relieve the most overloaded line
        {new_dispatch, line_shadow} =
          relieve_congestion(
            snapshot,
            dispatch,
            overloaded,
            solution,
            base_mva
          )

        updated_shadows = Map.merge(shadow_prices, line_shadow)

        iterate_opf(snapshot, new_dispatch, base_mva, max_iter, iter + 1, updated_shadows)
      end
    catch
      _, _ -> {dispatch, [], false, iter}
    end
  end

  # PTDF-based congestion relief: use Generation Shift Factors to find the
  # generators that most effectively relieve flow on the congested line, rather
  # than only considering generators at the line endpoints.
  defp relieve_congestion(snapshot, dispatch, overloaded, solution, _base_mva) do
    n = length(solution.bus_ids)
    bus_index = Map.new(Enum.zip(solution.bus_ids, 0..(n - 1)))

    # Build B' matrix (reduced, slack-deleted) for PTDF computation
    slack_idx = find_slack_index(snapshot.buses, snapshot.generators, bus_index)
    {remap, _inv_remap} = build_remap(n, slack_idx)
    n_reduced = n - 1

    {b_rows, b_cols, b_vals} =
      build_b_prime_coo(snapshot.lines, snapshot.transformers, bus_index, slack_idx, remap)

    # For the most overloaded line, compute GSFs for all generators
    {{worst_type, worst_id}, worst_flow} = hd(overloaded)

    excess_mw =
      abs(worst_flow.p_flow_mw) -
        abs(worst_flow.p_flow_mw) / worst_flow.loading_pct * 95.0

    excess_mw = max(excess_mw, 1.0)

    # Congested line susceptance
    from_idx = Map.get(bus_index, worst_flow.from_bus_id)
    to_idx = Map.get(bus_index, worst_flow.to_bus_id)
    from_reduced = Map.get(remap, from_idx)
    to_reduced = Map.get(remap, to_idx)

    # Solve B'^{-1} * (e_from - e_to) for the congested line's endpoints
    sensitivity =
      compute_ptdf_sensitivity(
        b_rows,
        b_cols,
        b_vals,
        n_reduced,
        from_reduced,
        to_reduced
      )

    # Compute line susceptance (b = 1/x)
    b_line = compute_congested_line_b(snapshot, worst_flow)

    # Compute GSF for each generator: GSF[g] = b_line * (x[gen_bus] - x[to_bus])
    # Positive GSF means the generator increases flow on the congested line
    gen_gsfs =
      compute_generator_gsfs(
        snapshot.generators,
        dispatch,
        bus_index,
        remap,
        sensitivity,
        b_line,
        to_reduced
      )

    # Sort by GSF: positive GSF generators increase congestion, negative decrease it
    # Reduce positive-GSF generators (they push flow onto the congested line)
    # Increase negative-GSF generators (they pull flow off)
    positive_gsf =
      gen_gsfs
      |> Enum.filter(fn g -> g.gsf > 0.01 end)
      # highest sensitivity first
      |> Enum.sort_by(fn g -> -g.gsf end)

    negative_gsf =
      gen_gsfs
      |> Enum.filter(fn g -> g.gsf < -0.01 end)
      # most negative first
      |> Enum.sort_by(fn g -> g.gsf end)

    # Compute shadow price: cost difference between expensive generator backed down
    # and cheap generator increased (approximation of congestion rent)
    compute_shadow = fn sending_gens, receiving_gens ->
      max_cost = sending_gens |> Enum.map(& &1.cost) |> Enum.max(fn -> 0.0 end)
      min_cost = receiving_gens |> Enum.map(& &1.cost) |> Enum.min(fn -> 0.0 end)
      max(max_cost - min_cost, 0.0)
    end

    # If no PTDF-based generators found, fall back to endpoint generators
    if Enum.empty?(positive_gsf) and Enum.empty?(negative_gsf) do
      gen_by_bus = Enum.group_by(snapshot.generators, & &1.bus_id)

      {sending_bus, receiving_bus} =
        if worst_flow.p_flow_mw > 0 do
          {worst_flow.from_bus_id, worst_flow.to_bus_id}
        else
          {worst_flow.to_bus_id, worst_flow.from_bus_id}
        end

      sending = find_nearby_generators(sending_bus, gen_by_bus, dispatch)
      receiving = find_nearby_generators(receiving_bus, gen_by_bus, dispatch)
      shadow = compute_shadow.(sending, receiving)

      new_dispatch =
        shift_generation(dispatch, sending, receiving, excess_mw, snapshot.generators)

      {new_dispatch, %{{worst_type, worst_id} => shadow}}
    else
      # Scale shift amount by GSF magnitude for effectiveness
      sending =
        Enum.map(positive_gsf, fn g ->
          %{
            id: g.id,
            dispatch: g.dispatch,
            p_max_mw: g.p_max_mw,
            p_min_mw: g.p_min_mw,
            cost: g.cost
          }
        end)

      receiving =
        Enum.map(negative_gsf, fn g ->
          %{
            id: g.id,
            dispatch: g.dispatch,
            p_max_mw: g.p_max_mw,
            p_min_mw: g.p_min_mw,
            cost: g.cost
          }
        end)

      shadow = compute_shadow.(sending, receiving)

      new_dispatch =
        shift_generation(dispatch, sending, receiving, excess_mw, snapshot.generators)

      {new_dispatch, %{{worst_type, worst_id} => shadow}}
    end
  end

  defp find_nearby_generators(bus_id, gen_by_bus, dispatch) do
    Map.get(gen_by_bus, bus_id, [])
    |> Enum.map(fn g ->
      %{
        id: g.id,
        dispatch: Map.get(dispatch, g.id, 0.0),
        p_max_mw: g.p_max_mw,
        p_min_mw: Map.get(g, :p_min_mw) || 0.0,
        cost: Map.get(g, :marginal_cost_per_mwh) || 40.0
      }
    end)
    |> Enum.sort_by(& &1.cost)
  end

  # Compute B'^{-1} * (e_from - e_to) for the congested line endpoints
  defp compute_ptdf_sensitivity(b_rows, b_cols, b_vals, n_reduced, from_reduced, to_reduced) do
    rhs = List.duplicate(0.0, n_reduced)

    rhs =
      if from_reduced != nil do
        List.replace_at(rhs, from_reduced, 1.0)
      else
        rhs
      end

    rhs =
      if to_reduced != nil do
        List.replace_at(rhs, to_reduced, -1.0)
      else
        rhs
      end

    try do
      case Sparse.sparse_solve(b_rows, b_cols, b_vals, rhs, n_reduced) do
        {:ok, x} -> x
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  # Compute susceptance of the congested line
  defp compute_congested_line_b(snapshot, worst_flow) do
    line =
      Enum.find(snapshot.lines, fn l ->
        l.from_bus_id == worst_flow.from_bus_id and l.to_bus_id == worst_flow.to_bus_id
      end)

    xfmr =
      if line == nil do
        Enum.find(snapshot.transformers, fn t ->
          t.from_bus_id == worst_flow.from_bus_id and t.to_bus_id == worst_flow.to_bus_id
        end)
      end

    cond do
      line != nil -> 1.0 / (line.x_pu || 0.001)
      xfmr != nil -> 1.0 / (xfmr.x_pu || 0.001)
      # fallback
      true -> 100.0
    end
  end

  # Compute Generation Shift Factors for all dispatched generators
  # GSF[g] = b_line * (sensitivity[gen_bus] - sensitivity[to_bus])
  defp compute_generator_gsfs(
         generators,
         dispatch,
         bus_index,
         remap,
         sensitivity,
         b_line,
         to_reduced
       ) do
    if sensitivity == nil do
      []
    else
      sens_arr = :array.from_list(sensitivity)
      x_to = if to_reduced == nil, do: 0.0, else: :array.get(to_reduced, sens_arr)

      generators
      |> Enum.filter(fn g -> Map.get(dispatch, g.id, 0.0) > 0.0 end)
      |> Enum.map(fn g ->
        gen_orig_idx = Map.get(bus_index, g.bus_id)
        gen_reduced = if gen_orig_idx, do: Map.get(remap, gen_orig_idx)

        x_gen = if gen_reduced == nil, do: 0.0, else: :array.get(gen_reduced, sens_arr)

        gsf = b_line * (x_gen - x_to)

        %{
          id: g.id,
          gsf: gsf,
          dispatch: Map.get(dispatch, g.id, 0.0),
          p_max_mw: g.p_max_mw,
          p_min_mw: Map.get(g, :p_min_mw) || 0.0,
          cost: Map.get(g, :marginal_cost_per_mwh) || 40.0
        }
      end)
    end
  end

  # Build index remap: original -> reduced (skipping slack bus)
  defp find_slack_index(buses, generators, bus_index) do
    case Enum.find(buses, &(&1.bus_type == 3)) do
      nil ->
        gen_by_bus = Enum.group_by(generators, & &1.bus_id)

        {max_bus_id, _} =
          Enum.max_by(
            gen_by_bus,
            fn {_id, gens} ->
              Enum.sum_by(gens, & &1.p_max_mw)
            end,
            fn -> {hd(buses).id, []} end
          )

        Map.fetch!(bus_index, max_bus_id)

      slack ->
        Map.fetch!(bus_index, slack.id)
    end
  end

  defp build_remap(n, slack_idx) do
    {remap, inv, _} =
      Enum.reduce(0..(n - 1), {%{}, %{}, 0}, fn i, {m, inv, ri} ->
        if i == slack_idx do
          {m, inv, ri}
        else
          {Map.put(m, i, ri), Map.put(inv, ri, i), ri + 1}
        end
      end)

    {remap, inv}
  end

  defp build_b_prime_coo(lines, transformers, bus_index, slack_idx, remap) do
    triplets = %{}

    triplets =
      Enum.reduce(lines, triplets, fn line, bt ->
        i = Map.get(bus_index, line.from_bus_id)
        j = Map.get(bus_index, line.to_bus_id)

        if i == nil or j == nil do
          bt
        else
          x = line.x_pu || 0.001
          b = 1.0 / x

          bt
          |> maybe_add_triplet(i, i, b, slack_idx, remap)
          |> maybe_add_triplet(j, j, b, slack_idx, remap)
          |> maybe_add_triplet(i, j, -b, slack_idx, remap)
          |> maybe_add_triplet(j, i, -b, slack_idx, remap)
        end
      end)

    triplets =
      Enum.reduce(transformers, triplets, fn xfmr, bt ->
        i = Map.get(bus_index, xfmr.from_bus_id)
        j = Map.get(bus_index, xfmr.to_bus_id)

        if i == nil or j == nil do
          bt
        else
          x = xfmr.x_pu || 0.001
          t = xfmr.tap_ratio || 1.0
          y = 1.0 / x

          bt
          |> maybe_add_triplet(i, i, y / (t * t), slack_idx, remap)
          |> maybe_add_triplet(j, j, y, slack_idx, remap)
          |> maybe_add_triplet(i, j, -y / t, slack_idx, remap)
          |> maybe_add_triplet(j, i, -y / t, slack_idx, remap)
        end
      end)

    Enum.reduce(triplets, {[], [], []}, fn {{r, c}, v}, {rs, cs, vs} ->
      if abs(v) > 1.0e-15 do
        {[r | rs], [c | cs], [v | vs]}
      else
        {rs, cs, vs}
      end
    end)
  end

  defp maybe_add_triplet(bt, r, c, val, slack_idx, remap) do
    if r == slack_idx or c == slack_idx do
      bt
    else
      ri = Map.fetch!(remap, r)
      ci = Map.fetch!(remap, c)
      Map.update(bt, {ri, ci}, val, &(&1 + val))
    end
  end

  defp shift_generation(dispatch, sending, receiving, mw_to_shift, _generators) do
    # Reduce sending generators (most expensive first)
    {dispatch, reduced} =
      sending
      |> Enum.sort_by(fn g -> -g.cost end)
      |> Enum.reduce({dispatch, 0.0}, fn g, {d, shifted} ->
        if shifted >= mw_to_shift do
          {d, shifted}
        else
          reducible = max(g.dispatch - g.p_min_mw, 0.0)
          reduction = min(reducible, mw_to_shift - shifted)
          {Map.put(d, g.id, g.dispatch - reduction), shifted + reduction}
        end
      end)

    # Increase receiving generators (cheapest first)
    {dispatch, _} =
      receiving
      |> Enum.sort_by(fn g -> g.cost end)
      |> Enum.reduce({dispatch, 0.0}, fn g, {d, shifted} ->
        if shifted >= reduced do
          {d, shifted}
        else
          current = Map.get(d, g.id, g.dispatch)
          headroom = max(g.p_max_mw - current, 0.0)
          increase = min(headroom, reduced - shifted)
          {Map.put(d, g.id, current + increase), shifted + increase}
        end
      end)

    dispatch
  end

  # Compute Locational Marginal Prices
  # LMP = system lambda + congestion component + loss component
  # For DC OPF without losses: LMP_bus = marginal cost of the marginal generator
  # adjusted for congestion shadow prices
  defp compute_lmps(snapshot, dispatch, congested_lines, _base_mva) do
    # Find the marginal generator (most expensive dispatched generator not at limit)
    marginal_cost =
      snapshot.generators
      |> Enum.filter(fn g ->
        d = Map.get(dispatch, g.id, 0.0)
        d > 0.0 and d < g.p_max_mw * 0.99
      end)
      |> Enum.map(fn g -> Map.get(g, :marginal_cost_per_mwh) || 40.0 end)
      |> Enum.max(fn -> 40.0 end)

    # Base LMP = marginal cost at every bus
    bus_ids = Enum.map(snapshot.buses, & &1.id)

    # For congested lines, buses on the constrained side have higher LMPs
    congestion_adders = compute_congestion_adders(congested_lines)

    Map.new(bus_ids, fn bus_id ->
      adder = Map.get(congestion_adders, bus_id, 0.0)
      {bus_id, Float.round(marginal_cost + adder, 2)}
    end)
  end

  defp compute_congestion_adders(congested_lines) do
    Enum.reduce(congested_lines, %{}, fn line, acc ->
      shadow = Map.get(line, :shadow_price, 0.0)

      if shadow > 0.0 do
        # Add shadow price to receiving end, subtract from sending end
        from = Map.get(line, :from_bus_id)
        to = Map.get(line, :to_bus_id)

        acc
        |> Map.update(to, shadow, &(&1 + shadow))
        |> Map.update(from, -shadow, &(&1 - shadow))
      else
        acc
      end
    end)
  end
end
