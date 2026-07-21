defmodule PowerModel.Solver.NewtonRaphson do
  @moduledoc """
  AC Power Flow solver using Newton-Raphson method in polar coordinates.

  Solves the full AC power flow equations using the standard polar Newton-Raphson
  formulation with additive voltage updates, PV bus voltage enforcement,
  PV-to-PQ switching on reactive power limit violations, damped Newton
  step-size limiting for robust convergence, and ZIP voltage-dependent load
  modeling.

  Jacobian structure (standard polar NR):
    [ J1  J2 ] [ dtheta ]   [ dP ]
    [ J3  J4 ] [   dV   ] = [ dQ ]

  where dtheta variables are for all non-slack buses (PQ + PV),
  dV variables are only for PQ buses, and updates are additive:
    theta_new = theta_old + dtheta
    V_new     = V_old     + dV
  """

  alias PowerModel.Solver.{YBus, Solution, Sparse, LoadModel}

  @max_iterations 50
  @tolerance 1.0e-6
  @max_dtheta 0.5
  @max_dv 0.1

  defstruct [:ybus, :buses, :generators, :loads, :base_mva, :bus_index]

  @doc """
  Solve AC power flow using Newton-Raphson iteration.
  """
  def solve(snapshot, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)
    max_iter = Keyword.get(opts, :max_iterations, @max_iterations)
    tol = Keyword.get(opts, :tolerance, @tolerance)
    warm_start = Keyword.get(opts, :warm_start, nil)

    buses = snapshot.buses
    lines = snapshot.lines
    transformers = snapshot.transformers
    generators = snapshot.generators
    loads = snapshot.loads

    n = length(buses)
    if n == 0, do: throw({:error, :empty_grid})

    bus_index = buses |> Enum.with_index() |> Map.new(fn {b, i} -> {b.id, i} end)
    bus_ids = Enum.map(buses, & &1.id)

    # Build Y-bus
    ybus = YBus.build(buses, lines, transformers, base_mva)

    # Classify buses
    {pq_indices, pv_indices, slack_idx} = classify_buses(buses, generators, bus_index)

    # Generation power injections (constant across iterations)
    {p_gen, q_gen} = gen_injection(generators, bus_index, n, base_mva)

    # Build per-bus load aggregation for ZIP model recalculation each iteration
    bus_loads = aggregate_loads_by_bus(loads, bus_index)

    # Scheduled voltage magnitudes for PV buses using generator setpoints
    v_sched = scheduled_voltages(buses, generators, bus_index, n)

    # Q limits per bus (aggregated from all generators at that bus)
    q_limits = aggregate_q_limits(generators, bus_index, n, base_mva)

    # Initialize voltages: flat start (V=1.0, theta=0.0) then set PV/slack setpoints
    {vm, va} = initialize_voltages(n, warm_start, bus_ids, v_sched, pv_indices, slack_idx)

    # Y-bus as dense for small systems (will use sparse NIF for large)
    y_data = build_y_dense(ybus)

    # Newton-Raphson iteration with PV-to-PQ switching and ZIP load model
    {vm, va, converged, iter, max_mis, p_calc} =
      iterate(
        vm,
        va,
        y_data,
        p_gen,
        q_gen,
        v_sched,
        q_limits,
        pq_indices,
        pv_indices,
        slack_idx,
        n,
        max_iter,
        tol,
        bus_loads,
        base_mva
      )

    # Convert arrays back to lists for Solution struct
    vm_list = :array.to_list(vm)
    va_list = :array.to_list(va)

    # Compute line flows from converged voltages
    line_flows = compute_ac_line_flows(lines, transformers, vm, va, bus_index, base_mva)

    scheduled_gen_mw = compute_total_gen(generators, base_mva)

    totals =
      if converged and p_calc != nil do
        # Sum of net bus injections is exactly the network I^2*R loss; served
        # load is the ZIP-effective demand at the final voltage profile.
        total_loss_mw = base_mva * sum_array(p_calc, n)
        served_load_mw = served_load(bus_loads, vm, base_mva)
        total_gen_mw = served_load_mw + total_loss_mw

        %{
          total_gen_mw: total_gen_mw,
          total_load_mw: served_load_mw,
          total_loss_mw: total_loss_mw,
          slack_injection_mw: base_mva * :array.get(slack_idx, p_calc),
          mismatch_mw: total_gen_mw - scheduled_gen_mw
        }
      else
        # Not converged: report scheduled/nominal values and an unknown
        # mismatch rather than fabricating converged-looking numbers.
        %{
          total_gen_mw: scheduled_gen_mw,
          total_load_mw: compute_total_load(loads),
          total_loss_mw: 0.0,
          slack_injection_mw: 0.0,
          mismatch_mw: nil
        }
      end

    solution = %Solution{
      bus_ids: bus_ids,
      vm_pu: vm_list,
      va_rad: va_list,
      line_flows: line_flows,
      base_mva: base_mva,
      converged: converged,
      iterations: iter,
      max_mismatch: max_mis,
      total_gen_mw: totals.total_gen_mw,
      total_load_mw: totals.total_load_mw,
      total_loss_mw: totals.total_loss_mw,
      scheduled_gen_mw: scheduled_gen_mw,
      slack_bus_id: Enum.at(bus_ids, slack_idx),
      slack_injection_mw: totals.slack_injection_mw,
      mismatch_mw: totals.mismatch_mw
    }

    {:ok, solution}
  end

  defp sum_array(arr, n) do
    Enum.reduce(0..(n - 1), 0.0, fn i, acc -> acc + :array.get(i, arr) end)
  end

  defp served_load(bus_loads, vm, _base_mva) do
    Enum.reduce(bus_loads, 0.0, fn {bus_idx, loads_at_bus}, acc ->
      v = :array.get(bus_idx, vm)

      Enum.reduce(loads_at_bus, acc, fn load, acc2 ->
        {p_eff, _q_eff} = LoadModel.effective_load(load, v)
        acc2 + p_eff
      end)
    end)
  end

  defp classify_buses(buses, generators, bus_index) do
    gen_bus_ids = MapSet.new(Enum.map(generators, & &1.bus_id))

    slack_idx =
      case Enum.find(buses, &(&1.bus_type == 3)) do
        nil ->
          {max_id, _} =
            generators
            |> Enum.group_by(& &1.bus_id)
            |> Enum.max_by(
              fn {_id, gens} -> Enum.sum(Enum.map(gens, & &1.p_max_mw)) end,
              fn -> {hd(buses).id, []} end
            )

          Map.fetch!(bus_index, max_id)

        slack ->
          Map.fetch!(bus_index, slack.id)
      end

    pv_indices =
      buses
      |> Enum.with_index()
      |> Enum.filter(fn {bus, idx} ->
        idx != slack_idx and (bus.bus_type == 2 or MapSet.member?(gen_bus_ids, bus.id))
      end)
      |> Enum.map(&elem(&1, 1))

    pq_indices =
      buses
      |> Enum.with_index()
      |> Enum.filter(fn {_bus, idx} ->
        idx != slack_idx and idx not in pv_indices
      end)
      |> Enum.map(&elem(&1, 1))

    {pq_indices, pv_indices, slack_idx}
  end

  # Returns {p_gen_array, q_gen_array} with only generation injections (no loads).
  defp gen_injection(generators, bus_index, n, base_mva) do
    p = :array.new(n, default: 0.0)
    q = :array.new(n, default: 0.0)

    p =
      Enum.reduce(generators, p, fn gen, acc ->
        idx = Map.fetch!(bus_index, gen.bus_id)
        p_pu = gen.p_max_mw * (gen.capacity_factor || 1.0) / base_mva
        array_add(acc, idx, p_pu)
      end)

    {p, q}
  end

  # Group loads by bus index for efficient per-iteration ZIP recalculation.
  # Returns a map: bus_index -> list of load maps
  defp aggregate_loads_by_bus(loads, bus_index) do
    Enum.group_by(loads, fn load -> Map.fetch!(bus_index, load.bus_id) end)
  end

  # Combine generation injection (constant) with voltage-dependent load injection.
  # When vm is nil, uses V=1.0 (equivalent to constant-power loads).
  defp combine_gen_load(p_gen, q_gen, bus_loads, n, base_mva, vm) do
    # Start from generation arrays
    p =
      Enum.reduce(0..(n - 1), :array.new(n, default: 0.0), fn i, acc ->
        :array.set(i, :array.get(i, p_gen), acc)
      end)

    q =
      Enum.reduce(0..(n - 1), :array.new(n, default: 0.0), fn i, acc ->
        :array.set(i, :array.get(i, q_gen), acc)
      end)

    # Subtract load power (adjusted by ZIP model at current voltage)
    Enum.reduce(bus_loads, {p, q}, fn {bus_idx, loads_at_bus}, {pa, qa} ->
      v = if vm, do: :array.get(bus_idx, vm), else: 1.0

      Enum.reduce(loads_at_bus, {pa, qa}, fn load, {pa2, qa2} ->
        {p_eff, q_eff} = LoadModel.effective_load(load, v)

        {array_add(pa2, bus_idx, -(p_eff / base_mva)),
         array_add(qa2, bus_idx, -(q_eff / base_mva))}
      end)
    end)
  end

  # Returns :array of scheduled voltage magnitudes.
  # For PV buses and slack bus, use the generator voltage setpoint (bus.vm_pu).
  # For PQ buses, default to 1.0.
  defp scheduled_voltages(buses, generators, _bus_index, _n) do
    gen_bus_set = MapSet.new(Enum.map(generators, & &1.bus_id))

    buses
    |> Enum.map(fn bus ->
      if bus.bus_type == 3 or bus.bus_type == 2 or MapSet.member?(gen_bus_set, bus.id) do
        bus.vm_pu || 1.0
      else
        1.0
      end
    end)
    |> :array.from_list()
  end

  # Aggregate Q limits for each bus from all generators (in per-unit).
  # Returns a map: bus_index -> {q_min_pu, q_max_pu}
  defp aggregate_q_limits(generators, bus_index, _n, base_mva) do
    generators
    |> Enum.group_by(fn gen -> Map.fetch!(bus_index, gen.bus_id) end)
    |> Map.new(fn {idx, gens} ->
      q_min = Enum.sum(Enum.map(gens, fn g -> (g.q_min_mvar || -9999.0) / base_mva end))
      q_max = Enum.sum(Enum.map(gens, fn g -> (g.q_max_mvar || 9999.0) / base_mva end))
      {idx, {q_min, q_max}}
    end)
  end

  defp initialize_voltages(n, nil, _bus_ids, v_sched, pv_indices, slack_idx) do
    vm = :array.new(n, default: 1.0)
    va = :array.new(n, default: 0.0)

    vm = :array.set(slack_idx, :array.get(slack_idx, v_sched), vm)

    vm =
      Enum.reduce(pv_indices, vm, fn idx, acc ->
        :array.set(idx, :array.get(idx, v_sched), acc)
      end)

    {vm, va}
  end

  defp initialize_voltages(_n, %Solution{} = warm, bus_ids, v_sched, pv_indices, slack_idx) do
    vm =
      bus_ids
      |> Enum.map(fn id ->
        case Solution.bus_voltage(warm, id) do
          nil -> 1.0
          %{vm_pu: v} -> v
        end
      end)
      |> :array.from_list()

    va =
      bus_ids
      |> Enum.map(fn id ->
        case Solution.bus_voltage(warm, id) do
          nil -> 0.0
          %{va_rad: a} -> a
        end
      end)
      |> :array.from_list()

    vm = :array.set(slack_idx, :array.get(slack_idx, v_sched), vm)

    vm =
      Enum.reduce(pv_indices, vm, fn idx, acc ->
        :array.set(idx, :array.get(idx, v_sched), acc)
      end)

    {vm, va}
  end

  defp build_y_dense(ybus) do
    n = ybus.n
    g = :array.new(n * n, default: 0.0)
    b = :array.new(n * n, default: 0.0)

    {g, b} =
      Enum.reduce(ybus.triplets, {g, b}, fn {r, c, {re, im}}, {ga, ba} ->
        {array_add(ga, r * n + c, re), array_add(ba, r * n + c, im)}
      end)

    %{g: g, b: b, n: n}
  end

  defp iterate(
         vm,
         va,
         y_data,
         p_gen,
         q_gen,
         v_sched,
         q_limits,
         pq_indices,
         pv_indices,
         slack_idx,
         n,
         max_iter,
         tol,
         bus_loads,
         base_mva
       ) do
    outer_solve(
      vm,
      va,
      y_data,
      p_gen,
      q_gen,
      v_sched,
      q_limits,
      pq_indices,
      pv_indices,
      %{},
      slack_idx,
      n,
      max_iter,
      tol,
      bus_loads,
      base_mva,
      0,
      0
    )
  end

  @max_qlim_rounds 6

  # Outer-loop Q-limit enforcement (MATPOWER-style): converge with FIXED bus
  # types, then check generator Q limits at the converged operating point and
  # re-solve warm-started if the PV/PQ split changed. Switching inside the NR
  # iterations reacts to transient Q excursions of the half-converged state —
  # it either locks buses at limits spuriously or oscillates and diverges.
  defp outer_solve(
         vm,
         va,
         y_data,
         p_gen,
         q_gen,
         v_sched,
         q_limits,
         orig_pq,
         orig_pv,
         switched,
         slack_idx,
         n,
         max_iter,
         tol,
         bus_loads,
         base_mva,
         round,
         iters_so_far
       ) do
    pv_eff = orig_pv |> Enum.reject(&Map.has_key?(switched, &1)) |> Enum.sort()
    pq_eff = Enum.sort(orig_pq ++ Map.keys(switched))

    {vm, va, converged, iter, max_mis, p_calc, q_calc} =
      do_iterate(
        vm,
        va,
        y_data,
        p_gen,
        q_gen,
        v_sched,
        q_limits,
        pq_eff,
        pv_eff,
        switched,
        slack_idx,
        n,
        0,
        max_iter,
        tol,
        bus_loads,
        base_mva
      )

    total_iters = iters_so_far + iter

    if converged and round < @max_qlim_rounds do
      new_switched = update_pv_pq_switching(pv_eff, switched, q_calc, q_limits, vm, v_sched)

      if new_switched == switched do
        {vm, va, converged, total_iters, max_mis, p_calc}
      else
        outer_solve(
          vm,
          va,
          y_data,
          p_gen,
          q_gen,
          v_sched,
          q_limits,
          orig_pq,
          orig_pv,
          new_switched,
          slack_idx,
          n,
          max_iter,
          tol,
          bus_loads,
          base_mva,
          round + 1,
          total_iters
        )
      end
    else
      {vm, va, converged, total_iters, max_mis, p_calc}
    end
  end

  defp do_iterate(
         vm,
         va,
         _y_data,
         _p_gen,
         _q_gen,
         _v_sched,
         _q_limits,
         _pq,
         _pv,
         _switched,
         _slack,
         _n,
         iter,
         max_iter,
         _tol,
         _bus_loads,
         _base_mva
       )
       when iter >= max_iter do
    {vm, va, false, iter, :infinity, nil, nil}
  end

  defp do_iterate(
         vm,
         va,
         y_data,
         p_gen,
         q_gen,
         v_sched,
         q_limits,
         pq_indices,
         pv_indices,
         switched,
         slack_idx,
         n,
         iter,
         max_iter,
         tol,
         bus_loads,
         base_mva
       ) do
    # Enforce PV bus voltage magnitudes at their setpoints
    vm =
      Enum.reduce(pv_indices, vm, fn idx, acc ->
        :array.set(idx, :array.get(idx, v_sched), acc)
      end)

    # Recompute scheduled power with ZIP load model using current bus voltages
    {p_sched, q_sched} = combine_gen_load(p_gen, q_gen, bus_loads, n, base_mva, vm)

    # Buses switched to PQ by the outer Q-limit loop hold Q at the violated limit
    q_sched =
      Enum.reduce(switched, q_sched, fn {idx, {_side, q_lim}}, acc ->
        :array.set(idx, q_lim, acc)
      end)

    # Compute power injections from current voltages
    {p_calc, q_calc} = compute_power(vm, va, y_data, n)

    # Active power mismatch for PQ and PV buses (all non-slack)
    non_slack = (pq_indices ++ pv_indices) |> Enum.sort()

    dp =
      Enum.map(non_slack, fn i ->
        :array.get(i, p_sched) - :array.get(i, p_calc)
      end)

    # Reactive power mismatch for PQ buses only
    dq =
      Enum.map(pq_indices, fn i ->
        :array.get(i, q_sched) - :array.get(i, q_calc)
      end)

    mismatch = dp ++ dq
    max_mis = mismatch |> Enum.map(&abs/1) |> Enum.max(fn -> 0.0 end)

    cond do
      max_mis < tol ->
        {vm, va, true, iter + 1, max_mis, p_calc, q_calc}

      not is_number(max_mis) or max_mis > 1.0e10 ->
        {vm, va, false, iter + 1, max_mis, nil, nil}

      true ->
        j_size = length(non_slack) + length(pq_indices)

        non_slack_arr = :array.from_list(non_slack)
        pq_arr = :array.from_list(pq_indices)

        # ZIP load voltage sensitivity: the scheduled injection itself depends
        # on V, so d(load)/dV joins the J2/J4 diagonals. Omitting it leaves
        # the residual exact but degrades convergence from quadratic to linear.
        {dpload_dv, dqload_dv} = load_voltage_sensitivity(bus_loads, vm, n, base_mva)

        jacobian =
          build_jacobian(
            vm,
            va,
            y_data,
            p_calc,
            q_calc,
            non_slack_arr,
            pq_arr,
            length(non_slack),
            length(pq_indices),
            n,
            dpload_dv,
            dqload_dv
          )

        correction = solve_jacobian(jacobian, mismatch, j_size)
        correction = limit_step_size(correction, length(non_slack), length(pq_indices))

        n_ns = length(non_slack)

        va =
          Enum.with_index(non_slack)
          |> Enum.reduce(va, fn {bus_i, ci}, va_acc ->
            old = :array.get(bus_i, va_acc)
            :array.set(bus_i, old + :array.get(ci, correction), va_acc)
          end)

        vm =
          Enum.with_index(pq_indices)
          |> Enum.reduce(vm, fn {bus_i, ci}, vm_acc ->
            dv = :array.get(n_ns + ci, correction)
            v_old = :array.get(bus_i, vm_acc)
            vm_new = v_old + dv
            vm_new = max(vm_new, 0.5)
            vm_new = min(vm_new, 1.5)
            :array.set(bus_i, vm_new, vm_acc)
          end)

        do_iterate(
          vm,
          va,
          y_data,
          p_gen,
          q_gen,
          v_sched,
          q_limits,
          pq_indices,
          pv_indices,
          switched,
          slack_idx,
          n,
          iter + 1,
          max_iter,
          tol,
          bus_loads,
          base_mva
        )
    end
  end

  # PV/PQ switching with back-switching (standard criterion):
  #   - a PV bus whose computed network Q injection violates a limit becomes
  #     PQ with Q held at that limit;
  #   - a switched bus returns to PV when its voltage crosses back over the
  #     setpoint in the direction that relaxes the binding limit (held at
  #     q_max while V rose above setpoint, or at q_min while V fell below).
  # Without the second rule a transient Q excursion during early iterations
  # locks the bus at its limit and the solution converges to sagged voltages.
  # Returns the updated switched map: bus_idx => {:max | :min, q_limit_pu}.
  defp update_pv_pq_switching(pv_indices, switched, q_calc, q_limits, vm, v_sched) do
    switched =
      Enum.reduce(pv_indices, switched, fn idx, acc ->
        case Map.get(q_limits, idx) do
          nil ->
            acc

          {q_min, q_max} ->
            q_injected = :array.get(idx, q_calc)

            cond do
              q_injected > q_max -> Map.put(acc, idx, {:max, q_max})
              q_injected < q_min -> Map.put(acc, idx, {:min, q_min})
              true -> acc
            end
        end
      end)

    Enum.reduce(Map.keys(switched), switched, fn idx, acc ->
      v = :array.get(idx, vm)
      v_set = :array.get(idx, v_sched)

      case Map.fetch!(acc, idx) do
        {:max, _} when v > v_set -> Map.delete(acc, idx)
        {:min, _} when v < v_set -> Map.delete(acc, idx)
        _ -> acc
      end
    end)
  end

  defp limit_step_size(correction, n_ns, n_pq) do
    j_size = n_ns + n_pq

    scale =
      Enum.reduce(0..(j_size - 1), 1.0, fn i, acc ->
        val = abs(:array.get(i, correction))

        cond do
          i < n_ns and val > @max_dtheta ->
            min(acc, @max_dtheta / val)

          i >= n_ns and val > @max_dv ->
            min(acc, @max_dv / val)

          true ->
            acc
        end
      end)

    if scale < 1.0 do
      Enum.reduce(0..(j_size - 1), correction, fn i, acc ->
        :array.set(i, :array.get(i, acc) * scale, acc)
      end)
    else
      correction
    end
  end

  defp compute_power(vm, va, %{g: g, b: b, n: n}, _n) do
    p =
      for i <- 0..(n - 1) do
        Enum.reduce(0..(n - 1), 0.0, fn j, acc ->
          vi = :array.get(i, vm)
          vj = :array.get(j, vm)
          theta = :array.get(i, va) - :array.get(j, va)
          gij = :array.get(i * n + j, g)
          bij = :array.get(i * n + j, b)
          acc + vi * vj * (gij * :math.cos(theta) + bij * :math.sin(theta))
        end)
      end

    q =
      for i <- 0..(n - 1) do
        Enum.reduce(0..(n - 1), 0.0, fn j, acc ->
          vi = :array.get(i, vm)
          vj = :array.get(j, vm)
          theta = :array.get(i, va) - :array.get(j, va)
          gij = :array.get(i * n + j, g)
          bij = :array.get(i * n + j, b)
          acc + vi * vj * (gij * :math.sin(theta) - bij * :math.cos(theta))
        end)
      end

    {:array.from_list(p), :array.from_list(q)}
  end

  defp build_jacobian(
         vm,
         va,
         %{g: g, b: b, n: n},
         p_calc,
         q_calc,
         non_slack_arr,
         pq_arr,
         n_ns,
         n_pq,
         _n_total,
         dpload_dv,
         dqload_dv
       ) do
    j_size = n_ns + n_pq

    for row <- 0..(j_size - 1) do
      for col <- 0..(j_size - 1) do
        cond do
          row < n_ns and col < n_ns ->
            i = :array.get(row, non_slack_arr)
            j = :array.get(col, non_slack_arr)
            jacobian_j1(i, j, vm, va, g, b, n, p_calc, q_calc)

          row < n_ns and col >= n_ns ->
            i = :array.get(row, non_slack_arr)
            j = :array.get(col - n_ns, pq_arr)
            j2 = jacobian_j2(i, j, vm, va, g, b, n, p_calc)
            if i == j, do: j2 + :array.get(i, dpload_dv), else: j2

          row >= n_ns and col < n_ns ->
            i = :array.get(row - n_ns, pq_arr)
            j = :array.get(col, non_slack_arr)
            jacobian_j3(i, j, vm, va, g, b, n, p_calc, q_calc)

          true ->
            i = :array.get(row - n_ns, pq_arr)
            j = :array.get(col - n_ns, pq_arr)
            j4 = jacobian_j4(i, j, vm, va, g, b, n, q_calc)
            if i == j, do: j4 + :array.get(i, dqload_dv), else: j4
        end
      end
    end
  end

  # Per-bus d(P_load)/dV and d(Q_load)/dV of the ZIP model at the current
  # voltage, in per-unit. Zero for constant-power loads (dfactor_dv == 0).
  defp load_voltage_sensitivity(bus_loads, vm, n, base_mva) do
    dp = :array.new(n, default: 0.0)
    dq = :array.new(n, default: 0.0)

    Enum.reduce(bus_loads, {dp, dq}, fn {bus_idx, loads_at_bus}, {dpa, dqa} ->
      v = :array.get(bus_idx, vm)

      Enum.reduce(loads_at_bus, {dpa, dqa}, fn load, {dpa2, dqa2} ->
        df = LoadModel.dfactor_dv(Map.get(load, :load_type), v)

        if df == 0.0 do
          {dpa2, dqa2}
        else
          q0 = Map.get(load, :q_mvar) || 0.0

          {array_add(dpa2, bus_idx, load.p_mw * df / base_mva),
           array_add(dqa2, bus_idx, q0 * df / base_mva)}
        end
      end)
    end)
  end

  defp jacobian_j1(i, j, vm, _va, _g, b, n, _p_calc, q_calc) when i == j do
    -:array.get(i, q_calc) - :array.get(i, vm) * :array.get(i, vm) * :array.get(i * n + i, b)
  end

  defp jacobian_j1(i, j, vm, va, g, b, n, _p_calc, _q_calc) do
    vi = :array.get(i, vm)
    vj = :array.get(j, vm)
    theta = :array.get(i, va) - :array.get(j, va)
    gij = :array.get(i * n + j, g)
    bij = :array.get(i * n + j, b)
    vi * vj * (gij * :math.sin(theta) - bij * :math.cos(theta))
  end

  defp jacobian_j2(i, j, vm, _va, g, _b, n, p_calc) when i == j do
    vi = :array.get(i, vm)
    :array.get(i, p_calc) / vi + vi * :array.get(i * n + i, g)
  end

  defp jacobian_j2(i, j, vm, va, g, b, n, _p_calc) do
    vi = :array.get(i, vm)
    theta = :array.get(i, va) - :array.get(j, va)
    gij = :array.get(i * n + j, g)
    bij = :array.get(i * n + j, b)
    vi * (gij * :math.cos(theta) + bij * :math.sin(theta))
  end

  defp jacobian_j3(i, j, vm, _va, g, _b, n, p_calc, _q_calc) when i == j do
    :array.get(i, p_calc) - :array.get(i, vm) * :array.get(i, vm) * :array.get(i * n + i, g)
  end

  defp jacobian_j3(i, j, vm, va, g, b, n, _p_calc, _q_calc) do
    vi = :array.get(i, vm)
    vj = :array.get(j, vm)
    theta = :array.get(i, va) - :array.get(j, va)
    gij = :array.get(i * n + j, g)
    bij = :array.get(i * n + j, b)
    -vi * vj * (gij * :math.cos(theta) + bij * :math.sin(theta))
  end

  defp jacobian_j4(i, j, vm, _va, _g, b, n, q_calc) when i == j do
    vi = :array.get(i, vm)
    :array.get(i, q_calc) / vi - vi * :array.get(i * n + i, b)
  end

  defp jacobian_j4(i, j, vm, va, g, b, n, _q_calc) do
    vi = :array.get(i, vm)
    theta = :array.get(i, va) - :array.get(j, va)
    gij = :array.get(i * n + j, g)
    bij = :array.get(i * n + j, b)
    vi * (gij * :math.sin(theta) - bij * :math.cos(theta))
  end

  defp solve_jacobian(jacobian, mismatch, size) do
    try do
      case Sparse.lu_factorize(jacobian, size) do
        {:ok, l, u, perm} ->
          case Sparse.lu_solve(l, u, perm, mismatch) do
            {:ok, x} -> :array.from_list(x)
            _ -> solve_jacobian_gauss(jacobian, mismatch, size)
          end

        _ ->
          solve_jacobian_gauss(jacobian, mismatch, size)
      end
    rescue
      _ -> solve_jacobian_gauss(jacobian, mismatch, size)
    end
  end

  defp solve_jacobian_gauss(jacobian, mismatch, size) do
    aug =
      jacobian
      |> Enum.zip(mismatch)
      |> Enum.map(fn {row, bi} -> :array.from_list(row ++ [bi]) end)
      |> :array.from_list()

    aug =
      Enum.reduce(0..(size - 2), aug, fn k, aug ->
        {_max_val, max_row} =
          Enum.reduce(k..(size - 1), {abs(arr_elem(aug, k, k)), k}, fn i, {mv, mr} ->
            v = abs(arr_elem(aug, i, k))
            if v > mv, do: {v, i}, else: {mv, mr}
          end)

        aug =
          if max_row != k do
            row_k = :array.get(k, aug)
            row_m = :array.get(max_row, aug)
            aug |> :array.set(k, row_m) |> :array.set(max_row, row_k)
          else
            aug
          end

        pivot = arr_elem(aug, k, k)

        if abs(pivot) < 1.0e-15 do
          aug
        else
          Enum.reduce((k + 1)..(size - 1), aug, fn i, aug ->
            factor = arr_elem(aug, i, k) / pivot
            row_i = :array.get(i, aug)
            row_k = :array.get(k, aug)
            row_width = size + 1

            new_row =
              Enum.map(0..(row_width - 1), fn col ->
                :array.get(col, row_i) - factor * :array.get(col, row_k)
              end)

            :array.set(i, :array.from_list(new_row), aug)
          end)
        end
      end)

    x = :array.new(size, default: 0.0)

    Enum.reduce((size - 1)..0//-1, x, fn i, x ->
      row = :array.get(i, aug)
      diag = :array.get(i, row)

      if abs(diag) < 1.0e-15 do
        :array.set(i, 0.0, x)
      else
        sum =
          Enum.reduce((i + 1)..(size - 1)//1, 0.0, fn j, acc ->
            acc + :array.get(j, row) * :array.get(j, x)
          end)

        :array.set(i, (:array.get(size, row) - sum) / diag, x)
      end
    end)
  end

  defp arr_elem(aug, row, col) do
    :array.get(col, :array.get(row, aug))
  end

  defp compute_ac_line_flows(lines, transformers, vm, va, bus_index, base_mva) do
    line_flows =
      Enum.map(lines, fn line ->
        i = Map.fetch!(bus_index, line.from_bus_id)
        j = Map.fetch!(bus_index, line.to_bus_id)

        vi = :array.get(i, vm)
        vj = :array.get(j, vm)
        theta_ij = :array.get(i, va) - :array.get(j, va)

        r = line.r_pu || 0.0
        x = line.x_pu || 0.001
        b_sh = (line.b_pu || 0.0) / 2.0

        denom = r * r + x * x
        g = r / denom
        b = -x / denom

        p_ij = vi * vi * g - vi * vj * (g * :math.cos(theta_ij) + b * :math.sin(theta_ij))

        q_ij =
          -vi * vi * (b + b_sh) - vi * vj * (g * :math.sin(theta_ij) - b * :math.cos(theta_ij))

        s_ij = :math.sqrt(p_ij * p_ij + q_ij * q_ij) * base_mva

        rating = line.rating_a_mva
        rated? = is_number(rating) and rating > 0

        {{:line, line.id},
         %{
           from_bus_id: line.from_bus_id,
           to_bus_id: line.to_bus_id,
           p_flow_mw: p_ij * base_mva,
           q_flow_mvar: q_ij * base_mva,
           s_flow_mva: s_ij,
           rating_mva: rating,
           loading_pct: if(rated?, do: s_ij / rating * 100.0, else: 0.0),
           overloaded: rated? and s_ij > rating
         }}
      end)

    xfmr_flows =
      Enum.map(transformers, fn xfmr ->
        i = Map.fetch!(bus_index, xfmr.from_bus_id)
        j = Map.fetch!(bus_index, xfmr.to_bus_id)

        vi = :array.get(i, vm)
        vj = :array.get(j, vm)
        theta_ij = :array.get(i, va) - :array.get(j, va)
        t = xfmr.tap_ratio || 1.0

        r = xfmr.r_pu || 0.0
        x = xfmr.x_pu
        denom = r * r + x * x
        g = r / denom
        b = -x / denom

        p_ij =
          vi * vi * g / (t * t) -
            vi * vj / t * (g * :math.cos(theta_ij) + b * :math.sin(theta_ij))

        q_ij =
          -(vi * vi * b / (t * t)) -
            vi * vj / t * (g * :math.sin(theta_ij) - b * :math.cos(theta_ij))

        s_ij = :math.sqrt(p_ij * p_ij + q_ij * q_ij) * base_mva

        rating = xfmr.rated_mva
        rated? = is_number(rating) and rating > 0

        {{:transformer, xfmr.id},
         %{
           from_bus_id: xfmr.from_bus_id,
           to_bus_id: xfmr.to_bus_id,
           p_flow_mw: p_ij * base_mva,
           q_flow_mvar: q_ij * base_mva,
           s_flow_mva: s_ij,
           rating_mva: rating,
           loading_pct: if(rated?, do: s_ij / rating * 100.0, else: 0.0),
           overloaded: rated? and s_ij > rating
         }}
      end)

    Map.new(line_flows ++ xfmr_flows)
  end

  defp compute_total_gen(generators, _base_mva) do
    Enum.sum(Enum.map(generators, fn g -> g.p_max_mw * (g.capacity_factor || 1.0) end))
  end

  defp compute_total_load(loads) do
    Enum.sum(Enum.map(loads, & &1.p_mw))
  end

  defp array_add(arr, idx, val) do
    :array.set(idx, :array.get(idx, arr) + val, arr)
  end
end
