defmodule PowerModel.Solver.NewtonRaphson do
  @moduledoc """
  AC Power Flow solver using Newton-Raphson method in polar coordinates.

  Solves the full AC power flow equations using the standard polar Newton-Raphson
  formulation with additive voltage updates, PV bus voltage enforcement,
  PV-to-PQ switching on reactive power limit violations, per-variable
  step-size clamping for robust convergence, and ZIP voltage-dependent load
  modeling.

  Bus classification:
    - Slack (type 3): the single bus with the largest aggregate generation capacity.
    - PV (type 2): buses with aggregate generation > 50 MW (excluding slack).
    - PQ (type 1): all remaining buses.

  Reactive power limits are estimated from generator fuel type and MW capacity
  when explicit Q limits are not provided in the data.

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
  @tolerance 1.0e-4
  @max_dtheta 0.3
  @max_dv 0.1

  @pv_threshold_mw 50.0

  defstruct [:ybus, :buses, :generators, :loads, :base_mva, :bus_index]

  @doc """
  Solve AC power flow using Newton-Raphson iteration.

  ## Options

    * `:base_mva` - system base MVA (default 100.0)
    * `:max_iterations` - maximum NR iterations (default 50)
    * `:tolerance` - convergence tolerance on max mismatch in p.u. (default 1e-4)
    * `:warm_start` - a previous `%Solution{}` to initialize voltages from
    * `:pv_threshold_mw` - minimum aggregate generation MW for a bus to be PV (default 50.0)
  """
  def solve(snapshot, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)
    max_iter = Keyword.get(opts, :max_iterations, @max_iterations)
    tol = Keyword.get(opts, :tolerance, @tolerance)
    warm_start = Keyword.get(opts, :warm_start, nil)
    pv_threshold = Keyword.get(opts, :pv_threshold_mw, @pv_threshold_mw)

    buses = snapshot.buses
    lines = snapshot.lines
    transformers = snapshot.transformers
    generators = snapshot.generators
    loads = snapshot.loads

    n = length(buses)

    if n == 0 do
      {:error, :empty_grid}
    else
      bus_index = buses |> Enum.with_index() |> Map.new(fn {b, i} -> {b.id, i} end)
      bus_ids = Enum.map(buses, & &1.id)

      ybus = YBus.build(buses, lines, transformers, base_mva)

      gen_by_bus = Enum.group_by(generators, & &1.bus_id)

      {pq_indices, pv_indices, slack_idx} =
        classify_buses(buses, gen_by_bus, bus_index, pv_threshold)

      {p_gen, q_gen} = gen_injection(generators, bus_index, n, base_mva)

      bus_loads = aggregate_loads_by_bus(loads, bus_index)

      v_sched = scheduled_voltages(buses, pv_indices, slack_idx, n)

      q_limits = aggregate_q_limits(generators, bus_index, n, base_mva)

      {vm, va} = initialize_voltages(n, warm_start, bus_ids, v_sched, pv_indices, slack_idx)

      y_data = build_y_data(ybus)

      {vm, va, converged, iter, max_mis} =
        iterate(vm, va, y_data, p_gen, q_gen, v_sched, q_limits,
                pq_indices, pv_indices, slack_idx, n, max_iter, tol,
                bus_loads, base_mva)

      vm_list = :array.to_list(vm)
      va_list = :array.to_list(va)

      line_flows = compute_ac_line_flows(lines, transformers, vm, va, bus_index, base_mva)

      solution = %Solution{
        bus_ids: bus_ids,
        vm_pu: vm_list,
        va_rad: va_list,
        line_flows: line_flows,
        base_mva: base_mva,
        converged: converged,
        iterations: iter,
        max_mismatch: max_mis,
        total_gen_mw: compute_total_gen(generators, base_mva),
        total_load_mw: compute_total_load(loads),
        total_loss_mw: 0.0
      }

      {:ok, solution}
    end
  end

  defp classify_buses(buses, gen_by_bus, bus_index, pv_threshold) do
    bus_gen_capacity =
      Map.new(gen_by_bus, fn {bus_id, gens} ->
        {bus_id, Enum.sum(Enum.map(gens, & &1.p_max_mw))}
      end)

    slack_idx =
      case Enum.find(buses, &(&1.bus_type == 3)) do
        nil ->
          case Enum.max_by(bus_gen_capacity, fn {_id, cap} -> cap end, fn -> nil end) do
            nil -> 0
            {max_id, _cap} -> Map.fetch!(bus_index, max_id)
          end

        slack ->
          Map.fetch!(bus_index, slack.id)
      end

    pv_indices =
      buses
      |> Enum.with_index()
      |> Enum.filter(fn {bus, idx} ->
        if idx == slack_idx do
          false
        else
          bus.bus_type == 2 or
            Map.get(bus_gen_capacity, bus.id, 0.0) > pv_threshold
        end
      end)
      |> Enum.map(&elem(&1, 1))

    pv_set = MapSet.new(pv_indices)

    pq_indices =
      buses
      |> Enum.with_index()
      |> Enum.filter(fn {_bus, idx} ->
        idx != slack_idx and not MapSet.member?(pv_set, idx)
      end)
      |> Enum.map(&elem(&1, 1))

    {pq_indices, pv_indices, slack_idx}
  end

  defp gen_injection(generators, bus_index, n, base_mva) do
    p = :array.new(n, default: 0.0)
    q = :array.new(n, default: 0.0)

    {p, q} =
      Enum.reduce(generators, {p, q}, fn gen, {p_acc, q_acc} ->
        idx = Map.fetch!(bus_index, gen.bus_id)
        p_mw = (gen.p_max_mw || 0.0) * (gen.capacity_factor || 1.0)
        p_pu = p_mw / base_mva

        q_mw = cond do
          gen.q_max_mvar != nil and gen.q_min_mvar != nil ->
            (gen.q_max_mvar + gen.q_min_mvar) / 2.0
          gen.q_max_mvar != nil ->
            gen.q_max_mvar * 0.3
          true ->
            p_mw * 0.3287
        end
        q_pu = q_mw / base_mva

        {array_add(p_acc, idx, p_pu), array_add(q_acc, idx, q_pu)}
      end)

    {p, q}
  end

  defp aggregate_loads_by_bus(loads, bus_index) do
    Enum.group_by(loads, fn load -> Map.fetch!(bus_index, load.bus_id) end)
  end

  defp combine_gen_load(p_gen, q_gen, bus_loads, n, base_mva, vm) do
    p =
      Enum.reduce(0..(n - 1), :array.new(n, default: 0.0), fn i, acc ->
        :array.set(i, :array.get(i, p_gen), acc)
      end)

    q =
      Enum.reduce(0..(n - 1), :array.new(n, default: 0.0), fn i, acc ->
        :array.set(i, :array.get(i, q_gen), acc)
      end)

    Enum.reduce(bus_loads, {p, q}, fn {bus_idx, loads_at_bus}, {pa, qa} ->
      v = if vm, do: :array.get(bus_idx, vm), else: 1.0

      Enum.reduce(loads_at_bus, {pa, qa}, fn load, {pa2, qa2} ->
        {p_eff, q_eff} = LoadModel.effective_load(load, v)

        {array_add(pa2, bus_idx, -(p_eff / base_mva)),
         array_add(qa2, bus_idx, -(q_eff / base_mva))}
      end)
    end)
  end

  defp scheduled_voltages(buses, pv_indices, slack_idx, _n) do
    pv_set = MapSet.new(pv_indices)

    buses
    |> Enum.with_index()
    |> Enum.map(fn {bus, idx} ->
      if idx == slack_idx or MapSet.member?(pv_set, idx) do
        bus.vm_pu || 1.0
      else
        1.0
      end
    end)
    |> :array.from_list()
  end

  defp aggregate_q_limits(generators, bus_index, _n, base_mva) do
    generators
    |> Enum.group_by(fn gen -> Map.fetch!(bus_index, gen.bus_id) end)
    |> Map.new(fn {idx, gens} ->
      {q_min, q_max} =
        Enum.reduce(gens, {0.0, 0.0}, fn g, {qmin_acc, qmax_acc} ->
          p_max = g.p_max_mw

          {q_lo, q_hi} =
            cond do
              g.q_max_mvar != nil and g.q_min_mvar != nil ->
                {g.q_min_mvar, g.q_max_mvar}

              true ->
                estimate_q_limits(Map.get(g, :fuel_type), p_max)
            end

          {qmin_acc + q_lo / base_mva, qmax_acc + q_hi / base_mva}
        end)

      {idx, {q_min, q_max}}
    end)
  end

  defp estimate_q_limits(fuel_type, p_max_mw) do
    case fuel_type do
      ft when ft in ~w(NUC COL NG PET GEO BIT SUB LIG OG DFO RFO) ->
        {-0.3 * p_max_mw, 0.6 * p_max_mw}

      ft when ft in ~w(WND SUN) ->
        {-0.33 * p_max_mw, 0.33 * p_max_mw}

      ft when ft in ~w(WAT WH) ->
        {-0.25 * p_max_mw, 0.5 * p_max_mw}

      _ ->
        {-0.3 * p_max_mw, 0.5 * p_max_mw}
    end
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

  defp build_y_data(ybus) do
    n = ybus.n

    adj = :array.new(n, default: [])
    g_diag = :array.new(n, default: 0.0)
    b_diag = :array.new(n, default: 0.0)

    {adj, g_diag, b_diag} =
      Enum.reduce(ybus.triplets, {adj, g_diag, b_diag}, fn {r, c, {re, im}}, {a, gd, bd} ->
        if r == c do
          {a, array_add(gd, r, re), array_add(bd, r, im)}
        else
          neighbors = :array.get(r, a)
          a = :array.set(r, [{c, re, im} | neighbors], a)
          {a, gd, bd}
        end
      end)

    sparse = %{adj: adj, g_diag: g_diag, b_diag: b_diag, n: n}

    if n <= 200 do
      {g, b} = build_dense_gb(ybus)
      Map.merge(sparse, %{g: g, b: b, dense: true})
    else
      Map.put(sparse, :dense, false)
    end
  end

  defp build_dense_gb(ybus) do
    n = ybus.n
    g = :array.new(n * n, default: 0.0)
    b = :array.new(n * n, default: 0.0)

    Enum.reduce(ybus.triplets, {g, b}, fn {r, c, {re, im}}, {ga, ba} ->
      {array_add(ga, r * n + c, re), array_add(ba, r * n + c, im)}
    end)
  end

  defp iterate(
         vm, va, y_data, p_gen, q_gen, v_sched, q_limits,
         pq_indices, pv_indices, slack_idx, n, max_iter, tol,
         bus_loads, base_mva
       ) do
    do_iterate(
      vm, va, y_data, p_gen, q_gen, v_sched, q_limits,
      pq_indices, pv_indices, slack_idx, n, 0, max_iter, tol,
      bus_loads, base_mva
    )
  end

  defp do_iterate(
         vm, va, _y_data, _p_gen, _q_gen, _v_sched, _q_limits,
         _pq, _pv, _slack, _n, iter, max_iter, _tol, _bus_loads, _base_mva
       )
       when iter >= max_iter do
    {vm, va, false, iter, :infinity}
  end

  defp do_iterate(
         vm, va, y_data, p_gen, q_gen, v_sched, q_limits,
         pq_indices, pv_indices, slack_idx, n, iter, max_iter, tol,
         bus_loads, base_mva
       ) do
    vm =
      Enum.reduce(pv_indices, vm, fn idx, acc ->
        :array.set(idx, :array.get(idx, v_sched), acc)
      end)

    {p_sched, q_sched} = combine_gen_load(p_gen, q_gen, bus_loads, n, base_mva, vm)

    {p_calc, q_calc} = compute_power_sparse(vm, va, y_data, n)

    {pq_indices, pv_indices, q_sched} =
      check_pv_pq_switching(pv_indices, pq_indices, q_calc, q_limits, q_sched)

    non_slack = (pq_indices ++ pv_indices) |> Enum.sort()

    dp =
      Enum.map(non_slack, fn i ->
        :array.get(i, p_sched) - :array.get(i, p_calc)
      end)

    dq =
      Enum.map(pq_indices, fn i ->
        :array.get(i, q_sched) - :array.get(i, q_calc)
      end)

    mismatch = dp ++ dq
    max_mis = mismatch |> Enum.map(&abs/1) |> Enum.max(fn -> 0.0 end)

    cond do
      max_mis < tol ->
        {vm, va, true, iter + 1, max_mis}

      not is_number(max_mis) or max_mis > 1.0e10 ->
        {vm, va, false, iter + 1, max_mis}

      true ->
        j_size = length(non_slack) + length(pq_indices)

        non_slack_arr = :array.from_list(non_slack)
        pq_arr = :array.from_list(pq_indices)
        n_ns = length(non_slack)
        n_pq = length(pq_indices)

        jacobian =
          if y_data.dense do
            build_jacobian_dense(
              vm, va, y_data, p_calc, q_calc,
              non_slack_arr, pq_arr, n_ns, n_pq, n
            )
          else
            build_jacobian_sparse(
              vm, va, y_data, p_calc, q_calc,
              non_slack, pq_indices, n_ns, n_pq, n
            )
          end

        correction = solve_jacobian(jacobian, mismatch, j_size)
        correction = limit_step_size(correction, n_ns, n_pq)

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
          vm, va, y_data, p_gen, q_gen, v_sched, q_limits,
          pq_indices, pv_indices, slack_idx, n, iter + 1, max_iter, tol,
          bus_loads, base_mva
        )
    end
  end

  defp check_pv_pq_switching(pv_indices, pq_indices, q_calc, q_limits, q_sched) do
    {remaining_pv, switched_to_pq, updated_q_sched} =
      Enum.reduce(pv_indices, {[], [], q_sched}, fn idx, {pv_acc, pq_acc, qs_acc} ->
        q_injected = :array.get(idx, q_calc)

        case Map.get(q_limits, idx) do
          nil ->
            {[idx | pv_acc], pq_acc, qs_acc}

          {q_min, q_max} ->
            cond do
              q_injected > q_max ->
                {pv_acc, [idx | pq_acc], :array.set(idx, q_max, qs_acc)}

              q_injected < q_min ->
                {pv_acc, [idx | pq_acc], :array.set(idx, q_min, qs_acc)}

              true ->
                {[idx | pv_acc], pq_acc, qs_acc}
            end
        end
      end)

    new_pq = (pq_indices ++ Enum.reverse(switched_to_pq)) |> Enum.sort()
    new_pv = Enum.reverse(remaining_pv) |> Enum.sort()
    {new_pq, new_pv, updated_q_sched}
  end

  defp limit_step_size(correction, n_ns, n_pq) do
    j_size = n_ns + n_pq

    Enum.reduce(0..(j_size - 1), correction, fn i, acc ->
      val = :array.get(i, acc)

      clamped =
        cond do
          i < n_ns ->
            max(min(val, @max_dtheta), -@max_dtheta)

          true ->
            max(min(val, @max_dv), -@max_dv)
        end

      if clamped != val do
        :array.set(i, clamped, acc)
      else
        acc
      end
    end)
  end

  defp compute_power_sparse(vm, va, %{adj: adj, g_diag: g_diag, b_diag: b_diag, n: n}, _n) do
    p =
      for i <- 0..(n - 1) do
        vi = :array.get(i, vm)
        ai = :array.get(i, va)
        gii = :array.get(i, g_diag)
        bii = :array.get(i, b_diag)

        p_diag = vi * vi * gii

        neighbors = :array.get(i, adj)

        Enum.reduce(neighbors, p_diag, fn {j, gij, bij}, acc ->
          vj = :array.get(j, vm)
          theta = ai - :array.get(j, va)
          acc + vi * vj * (gij * :math.cos(theta) + bij * :math.sin(theta))
        end)
      end

    q =
      for i <- 0..(n - 1) do
        vi = :array.get(i, vm)
        ai = :array.get(i, va)
        bii = :array.get(i, b_diag)

        q_diag = -vi * vi * bii

        neighbors = :array.get(i, adj)

        Enum.reduce(neighbors, q_diag, fn {j, gij, bij}, acc ->
          vj = :array.get(j, vm)
          theta = ai - :array.get(j, va)
          acc + vi * vj * (gij * :math.sin(theta) - bij * :math.cos(theta))
        end)
      end

    {:array.from_list(p), :array.from_list(q)}
  end

  defp build_jacobian_dense(vm, va, %{g: g, b: b, n: n}, p_calc, q_calc,
                            non_slack_arr, pq_arr, n_ns, n_pq, _n_total) do
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
            jacobian_j2(i, j, vm, va, g, b, n, p_calc)

          row >= n_ns and col < n_ns ->
            i = :array.get(row - n_ns, pq_arr)
            j = :array.get(col, non_slack_arr)
            jacobian_j3(i, j, vm, va, g, b, n, p_calc, q_calc)

          true ->
            i = :array.get(row - n_ns, pq_arr)
            j = :array.get(col - n_ns, pq_arr)
            jacobian_j4(i, j, vm, va, g, b, n, q_calc)
        end
      end
    end
  end

  defp build_jacobian_sparse(vm, va, y_data, p_calc, q_calc,
                             non_slack_list, pq_list, n_ns, n_pq, n) do
    %{adj: adj} = y_data

    ns_arr = :array.from_list(non_slack_list)
    pq_arr = :array.from_list(pq_list)

    bus_neighbors =
      Enum.reduce(0..(n - 1), %{}, fn i, acc ->
        neighbors = :array.get(i, adj)
        neighbor_set = MapSet.new(Enum.map(neighbors, fn {j, _, _} -> j end))
        Map.put(acc, i, neighbor_set)
      end)

    j_size = n_ns + n_pq

    for row <- 0..(j_size - 1) do
      for col <- 0..(j_size - 1) do
        cond do
          row < n_ns and col < n_ns ->
            i = :array.get(row, ns_arr)
            j = :array.get(col, ns_arr)
            if i == j or MapSet.member?(Map.get(bus_neighbors, i, MapSet.new()), j) do
              jacobian_j1_sparse(i, j, vm, va, y_data, p_calc, q_calc, n)
            else
              0.0
            end

          row < n_ns and col >= n_ns ->
            i = :array.get(row, ns_arr)
            j = :array.get(col - n_ns, pq_arr)
            if i == j or MapSet.member?(Map.get(bus_neighbors, i, MapSet.new()), j) do
              jacobian_j2_sparse(i, j, vm, va, y_data, p_calc, n)
            else
              0.0
            end

          row >= n_ns and col < n_ns ->
            i = :array.get(row - n_ns, pq_arr)
            j = :array.get(col, ns_arr)
            if i == j or MapSet.member?(Map.get(bus_neighbors, i, MapSet.new()), j) do
              jacobian_j3_sparse(i, j, vm, va, y_data, p_calc, q_calc, n)
            else
              0.0
            end

          true ->
            i = :array.get(row - n_ns, pq_arr)
            j = :array.get(col - n_ns, pq_arr)
            if i == j or MapSet.member?(Map.get(bus_neighbors, i, MapSet.new()), j) do
              jacobian_j4_sparse(i, j, vm, va, y_data, q_calc, n)
            else
              0.0
            end
        end
      end
    end
  end

  defp jacobian_j1_sparse(i, i, vm, _va, %{b_diag: b_diag}, _p_calc, q_calc, _n) do
    -:array.get(i, q_calc) - :array.get(i, vm) * :array.get(i, vm) * :array.get(i, b_diag)
  end

  defp jacobian_j1_sparse(i, j, vm, va, %{adj: adj}, _p_calc, _q_calc, _n) do
    vi = :array.get(i, vm)
    vj = :array.get(j, vm)
    theta = :array.get(i, va) - :array.get(j, va)
    {gij, bij} = find_yij(adj, i, j)
    vi * vj * (gij * :math.sin(theta) - bij * :math.cos(theta))
  end

  defp jacobian_j2_sparse(i, i, vm, _va, %{g_diag: g_diag}, p_calc, _n) do
    vi = :array.get(i, vm)
    :array.get(i, p_calc) / vi + vi * :array.get(i, g_diag)
  end

  defp jacobian_j2_sparse(i, j, vm, va, %{adj: adj}, _p_calc, _n) do
    vi = :array.get(i, vm)
    theta = :array.get(i, va) - :array.get(j, va)
    {gij, bij} = find_yij(adj, i, j)
    vi * (gij * :math.cos(theta) + bij * :math.sin(theta))
  end

  defp jacobian_j3_sparse(i, i, vm, _va, %{g_diag: g_diag}, p_calc, _q_calc, _n) do
    :array.get(i, p_calc) - :array.get(i, vm) * :array.get(i, vm) * :array.get(i, g_diag)
  end

  defp jacobian_j3_sparse(i, j, vm, va, %{adj: adj}, _p_calc, _q_calc, _n) do
    vi = :array.get(i, vm)
    vj = :array.get(j, vm)
    theta = :array.get(i, va) - :array.get(j, va)
    {gij, bij} = find_yij(adj, i, j)
    -vi * vj * (gij * :math.cos(theta) + bij * :math.sin(theta))
  end

  defp jacobian_j4_sparse(i, i, vm, _va, %{b_diag: b_diag}, q_calc, _n) do
    vi = :array.get(i, vm)
    :array.get(i, q_calc) / vi - vi * :array.get(i, b_diag)
  end

  defp jacobian_j4_sparse(i, j, vm, va, %{adj: adj}, _q_calc, _n) do
    vi = :array.get(i, vm)
    theta = :array.get(i, va) - :array.get(j, va)
    {gij, bij} = find_yij(adj, i, j)
    vi * (gij * :math.sin(theta) - bij * :math.cos(theta))
  end

  defp find_yij(adj, i, j) do
    neighbors = :array.get(i, adj)
    case Enum.find(neighbors, fn {k, _, _} -> k == j end) do
      {_, gij, bij} -> {gij, bij}
      nil -> {0.0, 0.0}
    end
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
    if size <= 200 do
      solve_jacobian_small(jacobian, mismatch, size)
    else
      solve_jacobian_large(jacobian, mismatch, size)
    end
  end

  defp solve_jacobian_small(jacobian, mismatch, size) do
    try do
      case Sparse.lu_factorize(jacobian, size) do
        {:ok, l, u, perm} ->
          case Sparse.lu_solve(l, u, perm, mismatch) do
            {:ok, x} -> :array.from_list(x)
            _ -> solve_jacobian_nx(jacobian, mismatch, size)
          end

        _ ->
          solve_jacobian_nx(jacobian, mismatch, size)
      end
    rescue
      _ -> solve_jacobian_nx(jacobian, mismatch, size)
    end
  end

  defp solve_jacobian_large(jacobian, mismatch, size) do
    solve_jacobian_nx(jacobian, mismatch, size)
  end

  defp solve_jacobian_nx(jacobian, mismatch, size) do
    try do
      a = Nx.tensor(jacobian, type: :f64)
      b = Nx.tensor(mismatch, type: :f64)
      x = Nx.LinAlg.solve(a, b) |> Nx.to_flat_list()
      :array.from_list(x)
    rescue
      _ ->
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
  end

  defp solve_jacobian_gauss(jacobian, mismatch, size) do
    aug =
      jacobian
      |> Enum.zip(mismatch)
      |> Enum.map(fn {row, bi} -> :array.from_list(row ++ [bi]) end)
      |> :array.from_list()

    aug =
      Enum.reduce(0..(size - 2)//1, aug, fn k, aug ->
        {_max_val, max_row} =
          Enum.reduce(k..(size - 1)//1, {abs(arr_elem(aug, k, k)), k}, fn i, {mv, mr} ->
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
          Enum.reduce((k + 1)..(size - 1)//1, aug, fn i, aug ->
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

        {{:line, line.id},
         %{
           from_bus_id: line.from_bus_id,
           to_bus_id: line.to_bus_id,
           p_flow_mw: p_ij * base_mva,
           q_flow_mvar: q_ij * base_mva,
           s_flow_mva: s_ij,
           loading_pct:
             if(line.rating_a_mva && line.rating_a_mva > 0,
               do: s_ij / line.rating_a_mva * 100.0,
               else: 0.0
             ),
           overloaded: line.rating_a_mva != nil and s_ij > (line.rating_a_mva || 999_999)
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

        {{:transformer, xfmr.id},
         %{
           from_bus_id: xfmr.from_bus_id,
           to_bus_id: xfmr.to_bus_id,
           p_flow_mw: p_ij * base_mva,
           q_flow_mvar: q_ij * base_mva,
           s_flow_mva: s_ij,
           loading_pct:
             if(xfmr.rated_mva > 0,
               do: s_ij / xfmr.rated_mva * 100.0,
               else: 0.0
             ),
           overloaded: s_ij > xfmr.rated_mva
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
