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

  ## Sparse math for large grids

  For grids with more than 200 buses, the Jacobian is built in COO (coordinate)
  triplet format, iterating only over non-zero entries (diagonal + adjacency
  neighbors), giving O(nnz) construction instead of O(n²). The admittance
  lookup uses a pre-built Map-of-Maps (`yij_map`) for O(1) element access.

  Solve strategy by grid size:
    - n <= 200:    Dense Rust NIF LU (`Sparse.lu_factorize`)
    - n > 200:     Sparse LU via faer NIF (`Sparse.sparse_lu_solve`), falling
                   back to dense NIF LU, normal equations (J^T J with LDL^T),
                   Nx dense, or Gaussian elimination
  """

  alias PowerModel.Solver.{YBus, Solution, Sparse, LoadModel, EconomicDispatch}

  @max_iterations 50
  @tolerance 1.0e-4
  @max_dtheta 0.5
  @max_dv 0.2

  @pv_threshold_mw 50.0

  # Grid size threshold: below this we use dense NIF LU on nested lists
  @dense_nif_threshold 200

  defstruct [:ybus, :buses, :generators, :loads, :base_mva, :bus_index]

  @doc """
  Solve AC power flow using Newton-Raphson iteration.

  ## Options

    * `:base_mva` - system base MVA (default 100.0)
    * `:max_iterations` - maximum NR iterations (default 50)
    * `:tolerance` - convergence tolerance on max mismatch in p.u. (default 1e-4)
    * `:warm_start` - a previous `%Solution{}` to initialize voltages from
    * `:use_bus_profiles` - if true, initialize V and angle from bus.vm_pu/va_rad (default false)
    * `:skip_dispatch` - if true, use generator capacity_factor * p_max as-is (default false)
    * `:pv_threshold_mw` - minimum aggregate generation MW for a bus to be PV (default 50.0)
  """
  def solve(snapshot, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)
    max_iter = Keyword.get(opts, :max_iterations, @max_iterations)
    tol = Keyword.get(opts, :tolerance, @tolerance)
    warm_start = Keyword.get(opts, :warm_start, nil)
    use_bus_profiles = Keyword.get(opts, :use_bus_profiles, false)
    skip_dispatch = Keyword.get(opts, :skip_dispatch, false)
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

      # Balance generation to match load via economic dispatch
      generators = if skip_dispatch do
        generators
      else
        total_load = Enum.sum(Enum.map(loads, & &1.p_mw))
        dispatch = EconomicDispatch.dispatch(generators, total_load)
        Enum.map(generators, fn g ->
          d = Map.get(dispatch, g.id, g.p_max_mw * (g.capacity_factor || 1.0))
          %{g | p_max_mw: d, capacity_factor: 1.0}
          |> Map.put(:p_nameplate_mw, g.p_max_mw)  # preserve original for Q capability curve
        end)
      end

      gen_by_bus = Enum.group_by(generators, & &1.bus_id)

      {pq_indices, pv_indices, slack_idx} =
        classify_buses(buses, gen_by_bus, bus_index, pv_threshold)

      {p_gen, q_gen} = gen_injection(generators, bus_index, n, base_mva)

      bus_loads = aggregate_loads_by_bus(loads, bus_index)

      v_sched = scheduled_voltages(buses, pv_indices, slack_idx, n, gen_by_bus)

      q_limits = aggregate_q_limits(generators, bus_index, n, base_mva)

      init = cond do
        warm_start != nil -> warm_start
        use_bus_profiles -> {:bus_profiles, buses}
        true -> nil
      end

      {vm, va} = initialize_voltages(n, init, bus_ids, v_sched, pv_indices, slack_idx)

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
        total_loss_mw: compute_total_losses(line_flows)
      }

      {:ok, solution}
    end
  end

  # ---------------------------------------------------------------------------
  # Bus classification
  # ---------------------------------------------------------------------------

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
          has_gen = Map.has_key?(gen_by_bus, bus.id)
          # PV if: bus is marked type 2 AND has generators (to provide Q),
          # or has large generation capacity regardless of bus_type
          (bus.bus_type == 2 and has_gen) or
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

  # ---------------------------------------------------------------------------
  # Generation / load injection
  # ---------------------------------------------------------------------------

  defp gen_injection(generators, bus_index, n, base_mva) do
    p = :array.new(n, default: 0.0)
    q = :array.new(n, default: 0.0)

    # Only schedule P from generators. Q is not scheduled because:
    # - PV buses: Q is a free variable (solver determines it from V constraint)
    # - PQ buses: Q_gen is unknown; scheduling (q_max+q_min)/2 causes divergence
    #   because the midpoint rarely matches what the network needs.
    #   Instead, Q_sched = -Q_load only, and voltages adjust to balance Q.
    {p, q} =
      Enum.reduce(generators, {p, q}, fn gen, {p_acc, q_acc} ->
        idx = Map.fetch!(bus_index, gen.bus_id)
        p_mw = (gen.p_max_mw || 0.0) * (gen.capacity_factor || 1.0)
        p_pu = p_mw / base_mva

        {array_add(p_acc, idx, p_pu), q_acc}
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

  defp scheduled_voltages(buses, pv_indices, slack_idx, _n, gen_by_bus) do
    pv_set = MapSet.new(pv_indices)

    buses
    |> Enum.with_index()
    |> Enum.map(fn {bus, idx} ->
      if idx == slack_idx or MapSet.member?(pv_set, idx) do
        # Prefer generator v_set_pu if available
        case Map.get(gen_by_bus, bus.id) do
          [gen | _] when gen.v_set_pu != nil and gen.v_set_pu > 0 -> gen.v_set_pu
          _ -> bus.vm_pu || 1.0
        end
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
          # p_max_mw is already set to dispatched value (from economic dispatch).
          # p_nameplate_mw preserves the original nameplate for S_rated computation.
          p_dispatch = g.p_max_mw
          p_nameplate = Map.get(g, :p_nameplate_mw, p_dispatch)

          {q_lo_rated, q_hi_rated} =
            cond do
              g.q_max_mvar != nil and g.q_min_mvar != nil ->
                {g.q_min_mvar, g.q_max_mvar}

              true ->
                estimate_q_limits(Map.get(g, :fuel_type), p_nameplate)
            end

          # Apply P-Q capability curve: use nameplate for S_rated, dispatch for Q_max(P)
          {q_lo, q_hi} = capability_q_limits(q_lo_rated, q_hi_rated, p_nameplate, p_dispatch)

          {qmin_acc + q_lo / base_mva, qmax_acc + q_hi / base_mva}
        end)

      {idx, {q_min, q_max}}
    end)
  end

  # P-Q capability curve: armature current limit.
  # S_rated = sqrt(P_max^2 + Q_max_rated^2) defines the MVA circle.
  # At dispatch P: Q_max(P) = sqrt(S_rated^2 - P^2)
  # At P = P_max: Q_max = Q_max_rated (by definition of the circle).
  # At P < P_max: Q_max > Q_max_rated (more Q headroom available).
  # Q_min (underexcited limit) stays roughly constant.
  defp capability_q_limits(q_min_rated, q_max_rated, p_max, p_dispatch) do
    if p_max <= 0.0 or q_max_rated <= 0.0 do
      {q_min_rated, q_max_rated}
    else
      s_rated_sq = p_max * p_max + q_max_rated * q_max_rated
      q_max = :math.sqrt(max(s_rated_sq - p_dispatch * p_dispatch, 0.0))
      # Cap at 2x rated to avoid unrealistic values at very low P
      q_max = min(q_max, q_max_rated * 2.0)
      # Ensure a minimum floor
      q_max = max(q_max, q_max_rated * 0.1)
      {q_min_rated, q_max}
    end
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

  # ---------------------------------------------------------------------------
  # Voltage initialization
  # ---------------------------------------------------------------------------

  defp initialize_voltages(n, nil, bus_ids, v_sched, pv_indices, slack_idx) do
    initialize_voltages(n, :from_buses, bus_ids, v_sched, pv_indices, slack_idx)
  end

  defp initialize_voltages(_n, :from_buses, _bus_ids, v_sched, pv_indices, slack_idx) do
    # Flat start: Vm=1.0, Va=0.0 for all buses
    # PV and slack buses get their scheduled voltage magnitudes
    vm = v_sched
    va = :array.new(:array.size(v_sched), default: 0.0)

    vm = :array.set(slack_idx, :array.get(slack_idx, v_sched), vm)

    vm =
      Enum.reduce(pv_indices, vm, fn idx, acc ->
        :array.set(idx, :array.get(idx, v_sched), acc)
      end)

    {vm, va}
  end

  # Initialize from bus-stored voltage profiles (from MATPOWER solved cases)
  defp initialize_voltages(_n, {:bus_profiles, buses}, _bus_ids, v_sched, pv_indices, slack_idx) do
    vm = buses
      |> Enum.map(fn b -> b.vm_pu || 1.0 end)
      |> :array.from_list()

    va = buses
      |> Enum.map(fn b -> b.va_rad || 0.0 end)
      |> :array.from_list()

    # Override PV/slack with scheduled values
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

  # ---------------------------------------------------------------------------
  # Y-bus data preparation — adjacency list + yij_map (Map of Maps)
  # ---------------------------------------------------------------------------

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

    # Build yij_map: %{i => %{j => {gij, bij}}} for O(1) admittance lookup.
    # This replaces the linear-search find_yij that was called per Jacobian element.
    yij_map = build_yij_map(adj, n)

    sparse = %{adj: adj, g_diag: g_diag, b_diag: b_diag, n: n, yij_map: yij_map}

    if n <= @dense_nif_threshold do
      {g, b} = build_dense_gb(ybus)
      Map.merge(sparse, %{g: g, b: b, dense: true})
    else
      Map.put(sparse, :dense, false)
    end
  end

  defp build_yij_map(adj, n) do
    Enum.reduce(0..(n - 1), %{}, fn i, outer_acc ->
      neighbors = :array.get(i, adj)
      inner_map =
        Enum.reduce(neighbors, %{}, fn {j, gij, bij}, inner_acc ->
          Map.put(inner_acc, j, {gij, bij})
        end)
      Map.put(outer_acc, i, inner_map)
    end)
  end

  defp build_dense_gb(ybus) do
    n = ybus.n
    g = :array.new(n * n, default: 0.0)
    b = :array.new(n * n, default: 0.0)

    Enum.reduce(ybus.triplets, {g, b}, fn {r, c, {re, im}}, {ga, ba} ->
      {array_add(ga, r * n + c, re), array_add(ba, r * n + c, im)}
    end)
  end

  # ---------------------------------------------------------------------------
  # Newton-Raphson iteration loop
  # ---------------------------------------------------------------------------

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

    # PV-PQ switching disabled — it causes divergence on large real grids
    # because Q_calc is unreliable during convergence and switching removes
    # voltage regulation at PV buses prematurely.
    # Q limits are still respected via the scheduled voltage magnitudes.
    {pq_indices, pv_indices, q_sched} = {pq_indices, pv_indices, q_sched}

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

      not is_number(max_mis) ->
        {vm, va, false, iter + 1, :infinity}

      true ->
        n_ns = length(non_slack)
        n_pq = length(pq_indices)
        j_size = n_ns + n_pq

        correction =
          if y_data.dense do
            # Small grid path: build dense list-of-lists Jacobian
            non_slack_arr = :array.from_list(non_slack)
            pq_arr = :array.from_list(pq_indices)

            jacobian =
              build_jacobian_dense(
                vm, va, y_data, p_calc, q_calc,
                non_slack_arr, pq_arr, n_ns, n_pq, n
              )

            solve_jacobian_dense(jacobian, mismatch, j_size)
          else
            # Large grid path: build COO triplets, solve with sparse/dense-flat strategy
            solve_jacobian_coo(
              vm, va, y_data, p_calc, q_calc,
              non_slack, pq_indices, n_ns, n_pq, n, mismatch, j_size
            )
          end

        correction = limit_step_size(correction, n_ns, n_pq)

        # Standard Newton step with mild damping only when mismatch is very large
        # Step clamping (@max_dtheta, @max_dv) provides the main safety net
        damping = if max_mis > 100.0, do: 0.5, else: 1.0

        va =
          Enum.with_index(non_slack)
          |> Enum.reduce(va, fn {bus_i, ci}, va_acc ->
            old = :array.get(bus_i, va_acc)
            :array.set(bus_i, old + damping * :array.get(ci, correction), va_acc)
          end)

        vm =
          Enum.with_index(pq_indices)
          |> Enum.reduce(vm, fn {bus_i, ci}, vm_acc ->
            dv = damping * :array.get(n_ns + ci, correction)
            v_old = :array.get(bus_i, vm_acc)
            vm_new = v_old + dv
            vm_new = max(vm_new, 0.7)
            vm_new = min(vm_new, 1.3)
            :array.set(bus_i, vm_new, vm_acc)
          end)

        do_iterate(
          vm, va, y_data, p_gen, q_gen, v_sched, q_limits,
          pq_indices, pv_indices, slack_idx, n, iter + 1, max_iter, tol,
          bus_loads, base_mva
        )
    end
  end

  # PV-PQ switching removed — causes divergence on large real grids.
  # Q limits enforced implicitly via PV bus voltage regulation.

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

  # ---------------------------------------------------------------------------
  # Power injection computation (sparse — iterates adjacency only)
  # ---------------------------------------------------------------------------

  defp compute_power_sparse(vm, va, %{adj: adj, g_diag: g_diag, b_diag: b_diag, n: n}, _n) do
    p =
      for i <- 0..(n - 1) do
        vi = :array.get(i, vm)
        ai = :array.get(i, va)
        gii = :array.get(i, g_diag)
        _bii = :array.get(i, b_diag)

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

  # ---------------------------------------------------------------------------
  # Dense Jacobian (small grids, n <= 200)
  # ---------------------------------------------------------------------------

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

  # Dense Jacobian element formulas (for small grid path, using dense g/b arrays)
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

  # ---------------------------------------------------------------------------
  # COO Jacobian build + sparse solve (large grids, n > 200)
  # ---------------------------------------------------------------------------

  # Build the Jacobian as COO triplets and solve the linear system.
  # Only iterates over non-zero entries: diagonals + adjacency neighbors.
  defp solve_jacobian_coo(vm, va, y_data, p_calc, q_calc,
                          non_slack, pq_indices, n_ns, _n_pq, n,
                          mismatch, j_size) do
    %{yij_map: yij_map, g_diag: g_diag, b_diag: b_diag, adj: adj} = y_data

    # Build reverse index maps: bus_index -> position in the Jacobian variable ordering
    # non_slack buses map to rows/cols 0..(n_ns-1) for dtheta
    # pq buses map to rows/cols n_ns..(j_size-1) for dV
    ns_pos = non_slack |> Enum.with_index() |> Map.new()
    pq_pos = pq_indices |> Enum.with_index() |> Map.new()

    # Accumulate COO triplets: {row_indices, col_indices, values}
    # Pre-size hint: diagonals contribute j_size entries,
    # off-diagonals contribute ~4 * avg_degree * n_ns entries (sparse)
    {coo_rows, coo_cols, coo_vals} =
      build_coo_triplets(
        vm, va, yij_map, g_diag, b_diag, adj, p_calc, q_calc,
        non_slack, pq_indices, ns_pos, pq_pos, n_ns, n
      )

    # Solve the system using the appropriate strategy
    solve_coo_system(coo_rows, coo_cols, coo_vals, mismatch, j_size, n)
  end

  # Build COO triplets by iterating only over non-zero entries.
  # For each bus i that is a Jacobian variable, emit:
  #   - Diagonal entries for J1(i,i), J2(i,i), J3(i,i), J4(i,i) as applicable
  #   - Off-diagonal entries for each neighbor j of bus i
  defp build_coo_triplets(
         vm, va, yij_map, g_diag, b_diag, adj, p_calc, q_calc,
         non_slack, pq_indices, ns_pos, pq_pos, n_ns, _n
       ) do
    # Process all non-slack buses for J1 (dP/dtheta) and J2 (dP/dV) blocks
    {rows1, cols1, vals1} =
      Enum.reduce(non_slack, {[], [], []}, fn i, {racc, cacc, vacc} ->
        row = Map.fetch!(ns_pos, i)
        vi = :array.get(i, vm)
        ai = :array.get(i, va)
        gii = :array.get(i, g_diag)
        bii = :array.get(i, b_diag)
        pi = :array.get(i, p_calc)
        qi = :array.get(i, q_calc)

        # J1 diagonal: dP_i/dtheta_i = -Q_i - Vi^2 * Bii
        j1_diag = -qi - vi * vi * bii
        racc = [row | racc]
        cacc = [row | cacc]
        vacc = [j1_diag | vacc]

        # J2 diagonal (only if i is PQ): dP_i/dV_i = P_i/Vi + Vi*Gii
        {racc, cacc, vacc} =
          case Map.get(pq_pos, i) do
            nil -> {racc, cacc, vacc}
            col_pq ->
              j2_diag = pi / vi + vi * gii
              {[row | racc], [n_ns + col_pq | cacc], [j2_diag | vacc]}
          end

        # Off-diagonal entries: iterate over neighbors of bus i
        neighbors = :array.get(i, adj)

        Enum.reduce(neighbors, {racc, cacc, vacc}, fn {j, _gij_unused, _bij_unused}, {r, c, v} ->
          {gij, bij} = get_yij(yij_map, i, j)
          vj = :array.get(j, vm)
          theta = ai - :array.get(j, va)
          sin_t = :math.sin(theta)
          cos_t = :math.cos(theta)

          # J1 off-diagonal: dP_i/dtheta_j (only if j is non-slack)
          {r, c, v} =
            case Map.get(ns_pos, j) do
              nil -> {r, c, v}
              col_j ->
                val = vi * vj * (gij * sin_t - bij * cos_t)
                {[row | r], [col_j | c], [val | v]}
            end

          # J2 off-diagonal: dP_i/dV_j (only if j is PQ)
          {r, c, v} =
            case Map.get(pq_pos, j) do
              nil -> {r, c, v}
              col_j ->
                val = vi * (gij * cos_t + bij * sin_t)
                {[row | r], [n_ns + col_j | c], [val | v]}
            end

          {r, c, v}
        end)
      end)

    # Process PQ buses for J3 (dQ/dtheta) and J4 (dQ/dV) blocks
    {rows2, cols2, vals2} =
      Enum.reduce(pq_indices, {[], [], []}, fn i, {racc, cacc, vacc} ->
        row_pq = Map.fetch!(pq_pos, i)
        row = n_ns + row_pq
        vi = :array.get(i, vm)
        ai = :array.get(i, va)
        gii = :array.get(i, g_diag)
        bii = :array.get(i, b_diag)
        pi = :array.get(i, p_calc)
        qi = :array.get(i, q_calc)

        # J3 diagonal: dQ_i/dtheta_i = P_i - Vi^2 * Gii
        j3_diag = pi - vi * vi * gii
        # i must be in ns_pos since PQ buses are non-slack
        col_ns = Map.fetch!(ns_pos, i)
        racc = [row | racc]
        cacc = [col_ns | cacc]
        vacc = [j3_diag | vacc]

        # J4 diagonal: dQ_i/dV_i = Q_i/Vi - Vi*Bii
        j4_diag = qi / vi - vi * bii
        racc = [row | racc]
        cacc = [n_ns + row_pq | cacc]
        vacc = [j4_diag | vacc]

        # Off-diagonal entries: iterate over neighbors of bus i
        neighbors = :array.get(i, adj)

        Enum.reduce(neighbors, {racc, cacc, vacc}, fn {j, _gij_unused, _bij_unused}, {r, c, v} ->
          {gij, bij} = get_yij(yij_map, i, j)
          vj = :array.get(j, vm)
          theta = ai - :array.get(j, va)
          sin_t = :math.sin(theta)
          cos_t = :math.cos(theta)

          # J3 off-diagonal: dQ_i/dtheta_j (only if j is non-slack)
          {r, c, v} =
            case Map.get(ns_pos, j) do
              nil -> {r, c, v}
              col_j ->
                val = -vi * vj * (gij * cos_t + bij * sin_t)
                {[row | r], [col_j | c], [val | v]}
            end

          # J4 off-diagonal: dQ_i/dV_j (only if j is PQ)
          {r, c, v} =
            case Map.get(pq_pos, j) do
              nil -> {r, c, v}
              col_j ->
                val = vi * (gij * sin_t - bij * cos_t)
                {[row | r], [n_ns + col_j | c], [val | v]}
            end

          {r, c, v}
        end)
      end)

    # Combine both halves
    {Enum.reverse(rows1) ++ Enum.reverse(rows2),
     Enum.reverse(cols1) ++ Enum.reverse(cols2),
     Enum.reverse(vals1) ++ Enum.reverse(vals2)}
  end

  # O(1) admittance lookup from pre-built Map of Maps
  defp get_yij(yij_map, i, j) do
    case yij_map do
      %{^i => %{^j => yij}} -> yij
      _ -> {0.0, 0.0}
    end
  end

  # ---------------------------------------------------------------------------
  # COO system solve strategies
  # ---------------------------------------------------------------------------

  # Choose the best solver based on grid size and NIF availability.
  # For n > 200 the primary solver is sparse LU via faer (handles asymmetric
  # Jacobians directly, O(nnz) complexity). Falls back to dense methods and
  # normal equations if the NIF is unavailable.
  defp solve_coo_system(coo_rows, coo_cols, coo_vals, mismatch, j_size, _n) do
    # Try sparse LU first — works for any size and handles asymmetric matrices
    case try_sparse_lu_solve(coo_rows, coo_cols, coo_vals, mismatch, j_size) do
      {:ok, x} ->
        :array.from_list(x)

      :fallback ->
        # Sparse LU unavailable or failed; fall back to dense/normal-equation chain
        solve_coo_fallback(coo_rows, coo_cols, coo_vals, mismatch, j_size)
    end
  end

  # Attempt sparse LU solve via the faer-based Rust NIF.
  defp try_sparse_lu_solve(coo_rows, coo_cols, coo_vals, mismatch, j_size) do
    try do
      case Sparse.sparse_lu_solve(coo_rows, coo_cols, coo_vals, mismatch, j_size) do
        {:ok, x} -> {:ok, x}
        {:error, _reason} -> :fallback
      end
    rescue
      ErlangError -> :fallback
    end
  end

  # Fallback chain when sparse LU is not available.
  defp solve_coo_fallback(coo_rows, coo_cols, coo_vals, mismatch, j_size) do
    # Try dense flat NIF (reasonable for j_size up to ~5000)
    case try_dense_solve_flat_from_coo(coo_rows, coo_cols, coo_vals, mismatch, j_size) do
      {:ok, x} ->
        :array.from_list(x)

      :fallback ->
        # Try normal equations with sparse LDL^T
        case try_normal_equations_sparse(coo_rows, coo_cols, coo_vals, mismatch, j_size) do
          {:ok, x} ->
            :array.from_list(x)

          :fallback ->
            # Try Nx dense solve
            case try_nx_solve_flat_from_coo(coo_rows, coo_cols, coo_vals, mismatch, j_size) do
              {:ok, x} ->
                :array.from_list(x)

              :fallback ->
                # Last resort: Gaussian elimination
                flat = coo_to_flat(coo_rows, coo_cols, coo_vals, j_size)
                jacobian = flat_to_nested(flat, j_size)
                solve_jacobian_gauss(jacobian, mismatch, j_size)
            end
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Normal equations: J^T J x = J^T b  (sparse LDL^T via Rust NIF)
  # ---------------------------------------------------------------------------

  # Compute J^T * J in COO format and J^T * b, then solve with sparse LDL^T.
  # The Jacobian is stored as COO triplets; we need to form the product J^T * J
  # efficiently. For a sparse matrix with nnz entries, J^T * J can be computed
  # by iterating over columns: for each column j, the non-zero rows form a
  # clique in J^T * J.
  defp try_normal_equations_sparse(coo_rows, coo_cols, coo_vals, mismatch, j_size) do
    try do
      # Group by row for J^T * b and J^T * J computation
      row_entries =
        coo_rows
        |> Enum.zip(coo_cols)
        |> Enum.zip(coo_vals)
        |> Enum.reduce(%{}, fn {{r, c}, v}, acc ->
          Map.update(acc, r, [{c, v}], fn existing -> [{c, v} | existing] end)
        end)

      # Compute J^T * b
      jtb = :array.new(j_size, default: 0.0)

      jtb =
        Enum.reduce(row_entries, jtb, fn {row_idx, entries}, acc ->
          b_r = Enum.at(mismatch, row_idx, 0.0)
          Enum.reduce(entries, acc, fn {col_idx, val}, acc2 ->
            # J^T[col_idx, row_idx] * b[row_idx] = val * b_r
            array_add(acc2, col_idx, val * b_r)
          end)
        end)

      jtb_list = :array.to_list(jtb)

      # Compute J^T * J in COO format
      # For each row r of J, the non-zero columns form pairs (ci, cj) where
      # (J^T J)[ci, cj] += J[r, ci] * J[r, cj]
      # We accumulate into a map %{{ci, cj} => val} to consolidate duplicates
      jtj_map =
        Enum.reduce(row_entries, %{}, fn {_row_idx, entries}, acc ->
          # entries is [{col_idx, val}, ...]
          # For all pairs (including diagonal), accumulate the outer product
          Enum.reduce(entries, acc, fn {ci, vi}, acc2 ->
            Enum.reduce(entries, acc2, fn {cj, vj}, acc3 ->
              Map.update(acc3, {ci, cj}, vi * vj, fn old -> old + vi * vj end)
            end)
          end)
        end)

      # Add Tikhonov regularization for numerical stability
      # This ensures J^T J + alpha*I is positive definite
      alpha = 1.0e-10

      jtj_map =
        Enum.reduce(0..(j_size - 1), jtj_map, fn i, acc ->
          Map.update(acc, {i, i}, alpha, fn old -> old + alpha end)
        end)

      # Convert to COO lists
      {jtj_rows, jtj_cols, jtj_vals} =
        Enum.reduce(jtj_map, {[], [], []}, fn {{r, c}, v}, {ra, ca, va} ->
          {[r | ra], [c | ca], [v | va]}
        end)

      # Solve with sparse LDL^T NIF
      case Sparse.sparse_solve(jtj_rows, jtj_cols, jtj_vals, jtb_list, j_size) do
        {:ok, x} -> {:ok, x}
        {:error, _reason} -> :fallback
      end
    rescue
      ErlangError -> :fallback
    end
  end

  # ---------------------------------------------------------------------------
  # Dense solve helpers
  # ---------------------------------------------------------------------------

  defp try_dense_solve_flat_from_coo(coo_rows, coo_cols, coo_vals, mismatch, j_size) do
    try do
      flat = coo_to_flat(coo_rows, coo_cols, coo_vals, j_size)
      case Sparse.dense_solve_flat(flat, mismatch, j_size) do
        {:ok, x} -> {:ok, x}
        {:error, _} -> :fallback
      end
    rescue
      ErlangError -> :fallback
    end
  end

  defp try_nx_solve_flat_from_coo(coo_rows, coo_cols, coo_vals, mismatch, j_size) do
    try do
      flat = coo_to_flat(coo_rows, coo_cols, coo_vals, j_size)
      a = flat |> Nx.tensor(type: :f64) |> Nx.reshape({j_size, j_size})
      b = Nx.tensor(mismatch, type: :f64)
      x = Nx.LinAlg.solve(a, b) |> Nx.to_flat_list()
      {:ok, x}
    rescue
      ArgumentError -> :fallback
    end
  end

  # Convert COO triplets to a flat row-major list (summing duplicate entries)
  defp coo_to_flat(coo_rows, coo_cols, coo_vals, j_size) do
    flat = :array.new(j_size * j_size, default: 0.0)

    flat =
      coo_rows
      |> Enum.zip(coo_cols)
      |> Enum.zip(coo_vals)
      |> Enum.reduce(flat, fn {{r, c}, v}, acc ->
        idx = r * j_size + c
        :array.set(idx, :array.get(idx, acc) + v, acc)
      end)

    :array.to_list(flat)
  end

  # Convert a flat row-major list to nested list-of-lists
  defp flat_to_nested(flat_list, j_size) do
    flat_list
    |> Enum.chunk_every(j_size)
  end

  # ---------------------------------------------------------------------------
  # Dense solve for small grid path
  # ---------------------------------------------------------------------------

  defp solve_jacobian_dense(jacobian, mismatch, size) do
    if size <= @dense_nif_threshold do
      solve_jacobian_small(jacobian, mismatch, size)
    else
      # Shouldn't reach here (dense path only for n <= 200) but handle gracefully
      solve_jacobian_nx(jacobian, mismatch, size)
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
      ErlangError -> solve_jacobian_nx(jacobian, mismatch, size)
    end
  end

  defp solve_jacobian_nx(jacobian, mismatch, size) do
    try do
      a = Nx.tensor(jacobian, type: :f64)
      b = Nx.tensor(mismatch, type: :f64)
      x = Nx.LinAlg.solve(a, b) |> Nx.to_flat_list()
      :array.from_list(x)
    rescue
      ArgumentError ->
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
          ErlangError -> solve_jacobian_gauss(jacobian, mismatch, size)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Gaussian elimination fallback (always works, O(n³))
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # AC line flow computation
  # ---------------------------------------------------------------------------

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
        p_ji = vj * vj * g - vj * vi * (g * :math.cos(-theta_ij) + b * :math.sin(-theta_ij))

        q_ij =
          -vi * vi * (b + b_sh) - vi * vj * (g * :math.sin(theta_ij) - b * :math.cos(theta_ij))

        s_ij = :math.sqrt(p_ij * p_ij + q_ij * q_ij) * base_mva
        loss_mw = (p_ij + p_ji) * base_mva

        {{:line, line.id},
         %{
           from_bus_id: line.from_bus_id,
           to_bus_id: line.to_bus_id,
           p_flow_mw: p_ij * base_mva,
           q_flow_mvar: q_ij * base_mva,
           s_flow_mva: s_ij,
           loss_mw: loss_mw,
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
        shift = (Map.get(xfmr, :phase_shift_deg) || 0.0) * :math.pi() / 180.0
        theta_ij = :array.get(i, va) - :array.get(j, va) - shift
        t = xfmr.tap_ratio || 1.0

        r = xfmr.r_pu || 0.0
        x = xfmr.x_pu
        denom = r * r + x * x
        g = r / denom
        b = -x / denom

        p_ij =
          vi * vi * g / (t * t) -
            vi * vj / t * (g * :math.cos(theta_ij) + b * :math.sin(theta_ij))

        p_ji =
          vj * vj * g -
            vj * vi / t * (g * :math.cos(-theta_ij) + b * :math.sin(-theta_ij))

        q_ij =
          -(vi * vi * b / (t * t)) -
            vi * vj / t * (g * :math.sin(theta_ij) - b * :math.cos(theta_ij))

        s_ij = :math.sqrt(p_ij * p_ij + q_ij * q_ij) * base_mva
        loss_mw = (p_ij + p_ji) * base_mva

        {{:transformer, xfmr.id},
         %{
           from_bus_id: xfmr.from_bus_id,
           to_bus_id: xfmr.to_bus_id,
           p_flow_mw: p_ij * base_mva,
           q_flow_mvar: q_ij * base_mva,
           s_flow_mva: s_ij,
           loss_mw: loss_mw,
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

  defp compute_total_losses(line_flows) do
    Enum.reduce(line_flows, 0.0, fn {_key, flow}, acc ->
      acc + (Map.get(flow, :loss_mw) || 0.0)
    end)
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
