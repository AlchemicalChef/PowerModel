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

  ## Scale

  The Jacobian here is dense: `build_jacobian/12` materializes a
  (2n)x(2n)-ish list of lists every iteration, so this path is a small-island
  solver by construction. `PowerModel.Solver.FDPF` is the one that scales, and
  it reuses everything in this module that is not the dense Jacobian —
  `prepare/2`, `power_injections/3`, `pv_pq_switching/1`, `build_solution/7`
  and the AC branch-flow computation — so the two solvers cannot drift apart in
  bus classification, injection modeling, Q-limit handling or reported flows.
  """

  alias PowerModel.Grid.Ratings
  alias PowerModel.Solver.{YBus, Solution, Sparse, LoadModel}

  require Logger

  @max_iterations 50
  @tolerance 1.0e-6
  @max_dtheta 0.5
  @max_dv 0.1

  # A power-flow problem with everything that does not change during the solve
  # already computed: bus classification, the Y-bus in nonzero-only form,
  # constant generator injections, scheduled voltages and aggregated Q limits.
  defstruct [
    :y_sparse,
    :buses,
    :lines,
    :transformers,
    :generators,
    :loads,
    :base_mva,
    :bus_index,
    :bus_ids,
    :n,
    :pq_indices,
    :pv_indices,
    :slack_idx,
    :p_gen,
    :q_gen,
    :v_sched,
    :q_limits,
    :bus_loads
  ]

  @doc """
  Solve AC power flow using Newton-Raphson iteration.
  """
  def solve(snapshot, opts \\ []) do
    max_iter = Keyword.get(opts, :max_iterations, @max_iterations)
    tol = Keyword.get(opts, :tolerance, @tolerance)
    warm_start = Keyword.get(opts, :warm_start, nil)

    prep = prepare(snapshot, opts)
    {vm, va} = initial_voltages(prep, warm_start)

    # Dense G/B, only ever built on this path: the Jacobian needs random
    # access to Y[i][j] for pairs that are structurally zero.
    y_data = build_y_dense(prep.y_sparse)

    qlim = %{
      switched: %{},
      released: MapSet.new(),
      latched: MapSet.new(),
      back_switch: back_switch?(opts)
    }

    {vm, va, converged, iter, max_mis, p_calc} =
      outer_solve(vm, va, y_data, prep, qlim, max_iter, tol, 0, 0)

    {:ok, build_solution(prep, vm, va, converged, iter, max_mis, p_calc)}
  end

  # ---------------------------------------------------------------------------
  # Problem setup, shared with FDPF
  # ---------------------------------------------------------------------------

  @doc """
  Build the invariant half of an AC power-flow problem from a snapshot.

  Everything here is a function of the topology and the dispatch, not of the
  voltage state, so it is computed once and reused by every iteration of
  whichever solver is driving.
  """
  def prepare(snapshot, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)

    buses = snapshot.buses
    lines = snapshot.lines
    transformers = snapshot.transformers
    generators = snapshot.generators
    loads = snapshot.loads

    n = length(buses)
    if n == 0, do: throw({:error, :empty_grid})

    bus_index = buses |> Enum.with_index() |> Map.new(fn {b, i} -> {b.id, i} end)

    # Duplicate bus ids make the Y-bus (sized by distinct ids) disagree with
    # every length(buses)-sized structure here, silently corrupting the solve.
    if map_size(bus_index) != n do
      raise ArgumentError,
            "snapshot contains duplicate bus ids: #{n} buses but only " <>
              "#{map_size(bus_index)} distinct ids"
    end

    {pq_indices, pv_indices, slack_idx} = classify_buses(buses, generators, bus_index)
    {p_gen, q_gen} = gen_injection(generators, bus_index, n, base_mva)

    %__MODULE__{
      y_sparse: ybus_adjacency(buses, lines, transformers, bus_index, base_mva),
      buses: buses,
      lines: lines,
      transformers: transformers,
      generators: generators,
      loads: loads,
      base_mva: base_mva,
      bus_index: bus_index,
      bus_ids: Enum.map(buses, & &1.id),
      n: n,
      pq_indices: pq_indices,
      pv_indices: pv_indices,
      slack_idx: slack_idx,
      p_gen: p_gen,
      q_gen: q_gen,
      v_sched: scheduled_voltages(buses, generators),
      q_limits: aggregate_q_limits(generators, bus_index, base_mva),
      bus_loads: aggregate_loads_by_bus(loads, bus_index)
    }
  end

  @doc """
  Assemble the Y-bus in nonzero-only form: per-bus diagonals plus, for each
  bus, the list of `{neighbour, G, B}` it actually connects to.

  This is the same matrix `PowerModel.Solver.YBus.build/4` produces, in the
  shape the power-injection sweep wants (and built in one prepend-only pass —
  `YBus.build/4` appends to a growing triplet list, which is quadratic in
  branch count and unusable past a few thousand branches).

  Duplicate positions — parallel branches, a transformer shadowing a line —
  are summed, exactly as the triplet consolidation does.
  """
  def ybus_adjacency(buses, lines, transformers, bus_index, base_mva) do
    n = map_size(bus_index)

    acc = {:array.new(n, default: 0.0), :array.new(n, default: 0.0), %{}}

    acc =
      Enum.reduce(lines, acc, fn line, acc ->
        i = Map.fetch!(bus_index, line.from_bus_id)
        j = Map.fetch!(bus_index, line.to_bus_id)

        r = Map.get(line, :r_pu) || 0.0
        x = YBus.effective_reactance(line.x_pu)
        b_shunt = (Map.get(line, :b_pu) || 0.0) / 2.0

        denom = r * r + x * x
        g_series = r / denom
        b_series = -x / denom

        acc
        |> add_diag(i, g_series, b_series + b_shunt)
        |> add_diag(j, g_series, b_series + b_shunt)
        |> add_off(i, j, -g_series, -b_series)
        |> add_off(j, i, -g_series, -b_series)
      end)

    acc =
      Enum.reduce(transformers, acc, fn xfmr, acc ->
        i = Map.fetch!(bus_index, xfmr.from_bus_id)
        j = Map.fetch!(bus_index, xfmr.to_bus_id)

        r = Map.get(xfmr, :r_pu) || 0.0
        x = YBus.effective_reactance(xfmr.x_pu)
        t = effective_tap_ratio(Map.get(xfmr, :tap_ratio))

        denom = r * r + x * x
        g = r / denom
        b = -x / denom

        acc
        |> add_diag(i, g / (t * t), b / (t * t))
        |> add_diag(j, g, b)
        |> add_off(i, j, -g / t, -b / t)
        |> add_off(j, i, -g / t, -b / t)
      end)

    # Bus shunt devices (capacitor banks, reactors): gs_mw + j*bs_mvar is the
    # power injected at V = 1.0 pu (MATPOWER convention), so the per-unit
    # admittance on the system base lands on the Y-bus diagonal.
    {gd, bd, off} =
      Enum.reduce(buses, acc, fn bus, acc ->
        gs = Map.get(bus, :gs_mw) || 0.0
        bs = Map.get(bus, :bs_mvar) || 0.0

        if gs == 0.0 and bs == 0.0 do
          acc
        else
          add_diag(acc, Map.fetch!(bus_index, bus.id), gs / base_mva, bs / base_mva)
        end
      end)

    nbrs = for i <- 0..(n - 1), do: sum_duplicates(Map.get(off, i, []))

    %{
      n: n,
      gd: gd |> :array.to_list() |> List.to_tuple(),
      bd: bd |> :array.to_list() |> List.to_tuple(),
      nbrs: List.to_tuple(nbrs)
    }
  end

  defp add_diag({gd, bd, off}, i, g, b) do
    {array_add(gd, i, g), array_add(bd, i, b), off}
  end

  defp add_off({gd, bd, off}, i, j, g, b) do
    {gd, bd, Map.update(off, i, [{j, g, b}], &[{j, g, b} | &1])}
  end

  # Parallel branches emit two entries for the same {i, j}; a single pass over
  # a short per-bus list is cheaper than a global consolidation.
  defp sum_duplicates([]), do: []
  defp sum_duplicates([single]), do: [single]

  defp sum_duplicates(entries) do
    entries
    |> Enum.reduce(%{}, fn {j, g, b}, acc ->
      Map.update(acc, j, {g, b}, fn {ga, ba} -> {ga + g, ba + b} end)
    end)
    |> Enum.map(fn {j, {g, b}} -> {j, g, b} end)
  end

  @doc """
  Bus power injections `{P, Q}` (per-unit `:array`s) at the given voltage state.

  Iterates the Y-bus nonzeros only. The dense form of this sweep visited all
  n^2 positions and recomputed `cos`/`sin` separately for the P and Q halves;
  on a real network with ~4 branches per bus that is two orders of magnitude of
  wasted work at a thousand buses and four at fifty thousand.
  """
  def power_injections(%{n: n, gd: gd, bd: bd, nbrs: nbrs}, vm, va) do
    # Tuples, not :array — this sweep is read-dominated (O(nnz) reads against
    # O(n) writes), and elem/2 is O(1) where :array.get/2 is a tree walk.
    vmt = vm |> :array.to_list() |> List.to_tuple()
    vat = va |> :array.to_list() |> List.to_tuple()

    {p, q} =
      Enum.reduce((n - 1)..0//-1, {[], []}, fn i, {p_acc, q_acc} ->
        vi = elem(vmt, i)
        ai = elem(vat, i)

        {p_sum, q_sum} =
          :lists.foldl(
            fn {j, gij, bij}, {p, q} ->
              theta = ai - elem(vat, j)
              vj = elem(vmt, j)
              cos = :math.cos(theta)
              sin = :math.sin(theta)
              {p + vj * (gij * cos + bij * sin), q + vj * (gij * sin - bij * cos)}
            end,
            # The j == i term: theta is zero, so it is V_i*G_ii for P and
            # -V_i*B_ii for Q.
            {vi * elem(gd, i), -(vi * elem(bd, i))},
            elem(nbrs, i)
          )

        {[vi * p_sum | p_acc], [vi * q_sum | q_acc]}
      end)

    {:array.from_list(p), :array.from_list(q)}
  end

  @doc """
  Scheduled bus injections `{P, Q}` at the given voltage magnitudes: constant
  generation minus ZIP-effective load. Q here is the *pre-limit* schedule (the
  negative of the reactive load); a solver holding a generator at a Q limit
  adds the limit on top.
  """
  def scheduled_injections(%__MODULE__{} = prep, vm) do
    Enum.reduce(prep.bus_loads, {prep.p_gen, prep.q_gen}, fn {bus_idx, loads_at_bus}, {pa, qa} ->
      v = :array.get(bus_idx, vm)

      Enum.reduce(loads_at_bus, {pa, qa}, fn load, {pa2, qa2} ->
        {p_eff, q_eff} = LoadModel.effective_load(load, v)

        {array_add(pa2, bus_idx, -(p_eff / prep.base_mva)),
         array_add(qa2, bus_idx, -(q_eff / prep.base_mva))}
      end)
    end)
  end

  @doc """
  Initial voltage state: a flat start, or a warm start read from a previous
  `Solution`, with PV and slack magnitudes forced to their setpoints.
  """
  def initial_voltages(%__MODULE__{} = prep, warm_start) do
    initialize_voltages(
      prep.n,
      warm_start,
      prep.bus_ids,
      prep.v_sched,
      prep.pv_indices,
      prep.slack_idx
    )
  end

  @doc """
  Assemble the `Solution` for a finished solve: branch flows at the solved
  voltages plus the energy-balance totals.
  """
  def build_solution(%__MODULE__{} = prep, vm, va, converged, iterations, max_mismatch, p_calc) do
    line_flows =
      compute_ac_line_flows(
        prep.lines,
        prep.transformers,
        vm,
        va,
        prep.bus_index,
        prep.base_mva
      )

    scheduled_gen_mw = compute_total_gen(prep.generators)

    totals =
      if converged and p_calc != nil do
        # Sum of net bus injections is exactly the network I^2*R loss; served
        # load is the ZIP-effective demand at the final voltage profile.
        total_loss_mw = prep.base_mva * sum_array(p_calc, prep.n)
        served_load_mw = served_load(prep.bus_loads, vm)
        total_gen_mw = served_load_mw + total_loss_mw

        %{
          total_gen_mw: total_gen_mw,
          total_load_mw: served_load_mw,
          total_loss_mw: total_loss_mw,
          slack_injection_mw: prep.base_mva * :array.get(prep.slack_idx, p_calc),
          mismatch_mw: total_gen_mw - scheduled_gen_mw
        }
      else
        # Not converged: report scheduled/nominal values and an unknown
        # mismatch rather than fabricating converged-looking numbers.
        %{
          total_gen_mw: scheduled_gen_mw,
          total_load_mw: compute_total_load(prep.loads),
          total_loss_mw: 0.0,
          slack_injection_mw: 0.0,
          mismatch_mw: nil
        }
      end

    %Solution{
      bus_ids: prep.bus_ids,
      vm_pu: :array.to_list(vm),
      va_rad: :array.to_list(va),
      line_flows: line_flows,
      base_mva: prep.base_mva,
      converged: converged,
      iterations: iterations,
      max_mismatch: max_mismatch,
      total_gen_mw: totals.total_gen_mw,
      total_load_mw: totals.total_load_mw,
      total_loss_mw: totals.total_loss_mw,
      scheduled_gen_mw: scheduled_gen_mw,
      slack_bus_id: Enum.at(prep.bus_ids, prep.slack_idx),
      slack_injection_mw: totals.slack_injection_mw,
      mismatch_mw: totals.mismatch_mw
    }
  end

  defp sum_array(arr, n) do
    Enum.reduce(0..(n - 1), 0.0, fn i, acc -> acc + :array.get(i, arr) end)
  end

  defp served_load(bus_loads, vm) do
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

  # Returns {p_gen_array, q_gen_array} with only generation injections (no loads).
  defp gen_injection(generators, bus_index, n, base_mva) do
    p = :array.new(n, default: 0.0)
    q = :array.new(n, default: 0.0)

    p =
      Enum.reduce(generators, p, fn gen, acc ->
        idx = Map.fetch!(bus_index, gen.bus_id)
        p_pu = gen.p_max_mw * (Map.get(gen, :capacity_factor) || 1.0) / base_mva
        array_add(acc, idx, p_pu)
      end)

    {p, q}
  end

  # Group loads by bus index for efficient per-iteration ZIP recalculation.
  # Returns a map: bus_index -> list of load maps
  defp aggregate_loads_by_bus(loads, bus_index) do
    Enum.group_by(loads, fn load -> Map.fetch!(bus_index, load.bus_id) end)
  end

  # Returns :array of scheduled voltage magnitudes.
  # For PV buses and slack bus, use the generator voltage setpoint (bus.vm_pu).
  # For PQ buses, default to 1.0.
  defp scheduled_voltages(buses, generators) do
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
  # Map.get, not dot access: generators arrive both as plain maps (tests,
  # cascade fixtures) and structs, and older fixtures lack the q-limit keys.
  defp aggregate_q_limits(generators, bus_index, base_mva) do
    generators
    |> Enum.group_by(fn gen -> Map.fetch!(bus_index, gen.bus_id) end)
    |> Map.new(fn {idx, gens} ->
      q_min =
        Enum.sum(Enum.map(gens, fn g -> (Map.get(g, :q_min_mvar) || -9999.0) / base_mva end))

      q_max =
        Enum.sum(Enum.map(gens, fn g -> (Map.get(g, :q_max_mvar) || 9999.0) / base_mva end))

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
    # One map, not a Solution.bus_voltage/2 lookup per bus: that helper scans
    # the id list and then indexes two more lists, so reading a whole warm
    # start through it is quadratic and dominated a large solve's setup.
    warm_by_id = warm_start_index(warm)

    {vm_list, va_list} =
      bus_ids
      |> Enum.map(fn id -> Map.get(warm_by_id, id, {1.0, 0.0}) end)
      |> Enum.unzip()

    vm = :array.from_list(vm_list)
    va = :array.from_list(va_list)

    vm = :array.set(slack_idx, :array.get(slack_idx, v_sched), vm)

    vm =
      Enum.reduce(pv_indices, vm, fn idx, acc ->
        :array.set(idx, :array.get(idx, v_sched), acc)
      end)

    {vm, va}
  end

  defp warm_start_index(%Solution{bus_ids: ids, vm_pu: vm, va_rad: va})
       when is_list(ids) and is_list(vm) and is_list(va) do
    [ids, vm, va]
    |> Enum.zip()
    |> Map.new(fn {id, v, a} -> {id, {v, a}} end)
  end

  defp warm_start_index(_), do: %{}

  # Dense G/B for the Jacobian, expanded from the nonzero-only Y-bus. Only the
  # dense NR path calls this, and only at sizes where n^2 is affordable.
  defp build_y_dense(%{n: n, gd: gd, bd: bd, nbrs: nbrs}) do
    g = :array.new(n * n, default: 0.0)
    b = :array.new(n * n, default: 0.0)

    {g, b} =
      Enum.reduce(0..(n - 1), {g, b}, fn i, acc ->
        {ga, ba} = acc
        acc = {:array.set(i * n + i, elem(gd, i), ga), :array.set(i * n + i, elem(bd, i), ba)}

        Enum.reduce(elem(nbrs, i), acc, fn {j, gij, bij}, {ga, ba} ->
          {:array.set(i * n + j, gij, ga), :array.set(i * n + j, bij, ba)}
        end)
      end)

    %{g: g, b: b, n: n}
  end

  @max_qlim_rounds 10

  # Outer-loop Q-limit enforcement (MATPOWER-style): converge with FIXED bus
  # types, then check generator Q limits at the converged operating point and
  # re-solve warm-started if the PV/PQ split changed. Switching inside the NR
  # iterations reacts to transient Q excursions of the half-converged state —
  # it either locks buses at limits spuriously or oscillates and diverges.
  defp outer_solve(vm, va, y_data, prep, qlim, max_iter, tol, round, iters_so_far) do
    switched = qlim.switched
    pv_eff = prep.pv_indices |> Enum.reject(&Map.has_key?(switched, &1)) |> Enum.sort()
    pq_eff = Enum.sort(prep.pq_indices ++ Map.keys(switched))

    {vm, va, converged, iter, max_mis, p_calc, q_calc, q_sched_pre} =
      do_iterate(vm, va, y_data, prep, pq_eff, pv_eff, switched, 0, max_iter, tol)

    total_iters = iters_so_far + iter

    if converged do
      {new_switched, released, latched} =
        pv_pq_switching(%{
          pv_indices: pv_eff,
          switched: switched,
          released: qlim.released,
          latched: qlim.latched,
          back_switch: qlim.back_switch,
          q_calc: q_calc,
          q_sched_pre: q_sched_pre,
          q_limits: prep.q_limits,
          vm: vm,
          v_sched: prep.v_sched
        })

      cond do
        new_switched == switched ->
          {vm, va, converged, total_iters, max_mis, p_calc}

        round < @max_qlim_rounds ->
          outer_solve(
            vm,
            va,
            y_data,
            prep,
            %{qlim | switched: new_switched, released: released, latched: latched},
            max_iter,
            tol,
            round + 1,
            total_iters
          )

        true ->
          Logger.warning(
            "AC solve reached the Q-limit switching round cap " <>
              "(#{@max_qlim_rounds}) while the PV/PQ switching set was still changing"
          )

          {vm, va, converged, total_iters, max_mis, p_calc}
      end
    else
      {vm, va, converged, total_iters, max_mis, p_calc}
    end
  end

  defp do_iterate(vm, va, _y_data, _prep, _pq, _pv, _switched, iter, max_iter, _tol)
       when iter >= max_iter do
    {vm, va, false, iter, :infinity, nil, nil, nil}
  end

  defp do_iterate(vm, va, y_data, prep, pq_indices, pv_indices, switched, iter, max_iter, tol) do
    n = prep.n

    # Enforce PV bus voltage magnitudes at their setpoints
    vm =
      Enum.reduce(pv_indices, vm, fn idx, acc ->
        :array.set(idx, :array.get(idx, prep.v_sched), acc)
      end)

    # Recompute scheduled power with ZIP load model using current bus voltages
    {p_sched, q_sched_pre} = scheduled_injections(prep, vm)
    q_sched = apply_q_clamps(q_sched_pre, switched)

    # Compute power injections from current voltages
    {p_calc, q_calc} = power_injections(prep.y_sparse, vm, va)

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
        {vm, va, true, iter + 1, max_mis, p_calc, q_calc, q_sched_pre}

      # `max_mis != max_mis` catches NaN (e.g. leaked from the NIF linear
      # solver), which passes both ordering comparisons unnoticed.
      not is_number(max_mis) or max_mis != max_mis or max_mis > 1.0e10 ->
        {vm, va, false, iter + 1, max_mis, nil, nil, nil}

      true ->
        j_size = length(non_slack) + length(pq_indices)

        non_slack_arr = :array.from_list(non_slack)
        pq_arr = :array.from_list(pq_indices)

        # ZIP load voltage sensitivity: the scheduled injection itself depends
        # on V, so d(load)/dV joins the J2/J4 diagonals. Omitting it leaves
        # the residual exact but degrades convergence from quadratic to linear.
        {dpload_dv, dqload_dv} = load_voltage_sensitivity(prep.bus_loads, vm, n, prep.base_mva)

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
          prep,
          pq_indices,
          pv_indices,
          switched,
          iter + 1,
          max_iter,
          tol
        )
    end
  end

  @doc """
  Buses switched to PQ hold generator output at the violated limit. Since the
  pre-limit schedule is negative effective load, the corresponding net-injection
  target is `q_limit + q_sched_pre`.
  """
  def apply_q_clamps(q_sched_pre, switched) do
    Enum.reduce(switched, q_sched_pre, fn {idx, {_side, q_lim}}, acc ->
      :array.set(idx, q_lim + :array.get(idx, q_sched_pre), acc)
    end)
  end

  @doc """
  PV/PQ switching for one Q-limit round, evaluated at a converged operating
  point. Returns `{switched, released, latched}`.

  Rules:

    * a PV bus whose computed generator Q output violates a limit becomes PQ
      with generator Q held at that limit (all violators in a round switch
      together — one-at-a-time switching costs a full re-solve per bus);
    * a switched bus returns to PV when its voltage crosses back over the
      setpoint in the direction that relaxes the binding limit (held at `q_max`
      while V rose above setpoint, or at `q_min` while V fell below);
    * a bus that violates again after having been released once latches at its
      limit for the rest of the solve.

  ## Why back-switching, and what it costs (REVIEW SOL-13)

  A converged Q-limit solution should satisfy the complementarity conditions
  every generator bus is subject to: regulating at setpoint with Q inside its
  range, **or** pinned at `q_max` with V at or below setpoint, **or** pinned at
  `q_min` with V at or above setpoint. A generator held at `q_max` whose
  voltage sits *above* its setpoint is not at a binding limit at all — it could
  simply absorb less and regulate. Rule two is what stops the solver from
  settling there.

  MATPOWER and PYPOWER's `enforce_q_lims` never back-switch, so they can and do
  settle there, and the committed ACTIVSg2000 reference was generated that way.
  Measured at the reference's own voltage solution: of its 195 off-setpoint
  generator buses, 48 are pinned at a limit their voltage says should not bind.
  This solver's answer disagrees with the reference on 32 of them (worst bus
  1070: we regulate at 1.040 pu drawing 18.8 MVAr, inside a 34.19 MVAr limit;
  the reference pins it at 34.19 MVAr and lets V float to 1.071 pu) and
  satisfies the complementarity conditions at all 392 generator buses, where
  the reference does not. Passing `back_switch: false` reproduces the
  reference's policy and, with it, the reference itself: 191 of 195 buses
  bus-for-bus, losses to 0.015%, worst angle 3.3e-3 rad. That is the measurement
  that separates a modeling error (there is none) from a policy difference
  (this is one).

  ## Termination

  The back-switch test reads a voltage that the *global* switching state
  determines, so nothing about it is locally monotone and a two-cycle is
  possible in principle. The latch bounds it: each bus can change type at most
  three times, so the round loop terminates on its own rather than on the round
  cap. On ACTIVSg2000 it settles in five rounds and the latch changes nothing —
  it is a guarantee, not a fix.
  """
  def pv_pq_switching(
        %{
          pv_indices: pv_indices,
          switched: switched,
          released: released,
          latched: latched,
          q_calc: q_calc,
          q_sched_pre: q_sched_pre,
          q_limits: q_limits,
          vm: vm,
          v_sched: v_sched
        } = input
      ) do
    back_switch = Map.get(input, :back_switch, true)

    {switched, latched} =
      Enum.reduce(pv_indices, {switched, latched}, fn idx, {acc, latch} = unchanged ->
        case Map.get(q_limits, idx) do
          nil ->
            unchanged

          {q_min, q_max} ->
            q_generated = :array.get(idx, q_calc) - :array.get(idx, q_sched_pre)

            cond do
              q_generated > q_max ->
                {Map.put(acc, idx, {:max, q_max}), relatch(latch, released, idx)}

              q_generated < q_min ->
                {Map.put(acc, idx, {:min, q_min}), relatch(latch, released, idx)}

              true ->
                unchanged
            end
        end
      end)

    if back_switch do
      Enum.reduce(Map.keys(switched), {switched, released, latched}, fn idx,
                                                                        {acc, rel, latch} =
                                                                          unchanged ->
        if MapSet.member?(latch, idx) do
          unchanged
        else
          v = :array.get(idx, vm)
          v_set = :array.get(idx, v_sched)

          case Map.fetch!(acc, idx) do
            {:max, _} when v > v_set -> {Map.delete(acc, idx), MapSet.put(rel, idx), latch}
            {:min, _} when v < v_set -> {Map.delete(acc, idx), MapSet.put(rel, idx), latch}
            _ -> unchanged
          end
        end
      end)
    else
      {switched, released, latched}
    end
  end

  @doc """
  Whether the `:q_limit_policy` option asks for back-switching.

  `:complementary` (the default) lets a generator resume voltage regulation
  when its voltage says the limit stopped binding. `:matpower` never releases a
  generator once it hits a limit, reproducing MATPOWER/PYPOWER `enforce_q_lims`
  — use it only to compare against references generated by those tools.
  """
  def back_switch?(opts) do
    case Keyword.get(opts, :q_limit_policy, :complementary) do
      :matpower -> false
      :complementary -> true
      other -> raise ArgumentError, "unknown :q_limit_policy #{inspect(other)}"
    end
  end

  defp relatch(latched, released, idx) do
    if MapSet.member?(released, idx), do: MapSet.put(latched, idx), else: latched
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

        # A vanishing pivot means the Jacobian is singular. Zeroing the free
        # variables and continuing would fabricate a Newton step out of thin
        # air, so error out like the DC solver's gaussian_solve does.
        if abs(pivot) < 1.0e-15, do: throw({:error, :singular_matrix})

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
      end)

    x = :array.new(size, default: 0.0)

    Enum.reduce((size - 1)..0//-1, x, fn i, x ->
      row = :array.get(i, aug)
      diag = :array.get(i, row)

      if abs(diag) < 1.0e-15, do: throw({:error, :singular_matrix})

      sum =
        Enum.reduce((i + 1)..(size - 1)//1, 0.0, fn j, acc ->
          acc + :array.get(j, row) * :array.get(j, x)
        end)

      :array.set(i, (:array.get(size, row) - sum) / diag, x)
    end)
  end

  defp arr_elem(aug, row, col) do
    :array.get(col, :array.get(row, aug))
  end

  @doc """
  Per-branch AC flows at the from terminal: P, Q, apparent power and loading
  against rates A/B/C.

  Shared with FDPF so that reported flows come from the same model the solve
  used, and so the voltage-driven protection layer (distance relays, UVLS)
  reads one definition of per-line Q.
  """
  def compute_ac_line_flows(lines, transformers, vm, va, bus_index, base_mva) do
    line_flows =
      Enum.map(lines, fn line ->
        i = Map.fetch!(bus_index, line.from_bus_id)
        j = Map.fetch!(bus_index, line.to_bus_id)

        vi = :array.get(i, vm)
        vj = :array.get(j, vm)
        theta_ij = :array.get(i, va) - :array.get(j, va)

        r = Map.get(line, :r_pu) || 0.0
        x = YBus.effective_reactance(line.x_pu)
        b_sh = (Map.get(line, :b_pu) || 0.0) / 2.0

        denom = r * r + x * x
        g = r / denom
        b = -x / denom

        p_ij = vi * vi * g - vi * vj * (g * :math.cos(theta_ij) + b * :math.sin(theta_ij))

        q_ij =
          -vi * vi * (b + b_sh) - vi * vj * (g * :math.sin(theta_ij) - b * :math.cos(theta_ij))

        s_ij = :math.sqrt(p_ij * p_ij + q_ij * q_ij) * base_mva

        {rate_a, rate_b, rate_c} = Ratings.branch_ratings(line)

        {{:line, line.id},
         %{
           from_bus_id: line.from_bus_id,
           to_bus_id: line.to_bus_id,
           p_flow_mw: p_ij * base_mva,
           q_flow_mvar: q_ij * base_mva,
           s_flow_mva: s_ij,
           rating_mva: rate_a,
           rating_b_mva: rate_b,
           rating_c_mva: rate_c,
           loading_pct: Ratings.loading_pct(s_ij, rate_a),
           emergency_loading_pct: Ratings.loading_pct(s_ij, rate_b),
           trip_loading_pct: Ratings.loading_pct(s_ij, rate_c),
           overloaded: is_number(rate_a) and s_ij > rate_a
         }}
      end)

    xfmr_flows =
      Enum.map(transformers, fn xfmr ->
        i = Map.fetch!(bus_index, xfmr.from_bus_id)
        j = Map.fetch!(bus_index, xfmr.to_bus_id)

        vi = :array.get(i, vm)
        vj = :array.get(j, vm)
        theta_ij = :array.get(i, va) - :array.get(j, va)
        t = effective_tap_ratio(Map.get(xfmr, :tap_ratio))

        r = Map.get(xfmr, :r_pu) || 0.0
        x = YBus.effective_reactance(xfmr.x_pu)
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

        {rate_a, rate_b, rate_c} = Ratings.branch_ratings(xfmr)

        {{:transformer, xfmr.id},
         %{
           from_bus_id: xfmr.from_bus_id,
           to_bus_id: xfmr.to_bus_id,
           p_flow_mw: p_ij * base_mva,
           q_flow_mvar: q_ij * base_mva,
           s_flow_mva: s_ij,
           rating_mva: rate_a,
           rating_b_mva: rate_b,
           rating_c_mva: rate_c,
           loading_pct: Ratings.loading_pct(s_ij, rate_a),
           emergency_loading_pct: Ratings.loading_pct(s_ij, rate_b),
           trip_loading_pct: Ratings.loading_pct(s_ij, rate_c),
           overloaded: is_number(rate_a) and s_ij > rate_a
         }}
      end)

    Map.new(line_flows ++ xfmr_flows)
  end

  defp compute_total_gen(generators) do
    Enum.sum(Enum.map(generators, fn g -> g.p_max_mw * (Map.get(g, :capacity_factor) || 1.0) end))
  end

  defp compute_total_load(loads) do
    Enum.sum(Enum.map(loads, & &1.p_mw))
  end

  defp effective_tap_ratio(t) when is_number(t) and t > 0.0, do: t
  defp effective_tap_ratio(_), do: 1.0

  defp array_add(arr, idx, val) do
    :array.set(idx, :array.get(idx, arr) + val, arr)
  end
end
