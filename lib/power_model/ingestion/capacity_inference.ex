defmodule PowerModel.Ingestion.CapacityInference do
  @moduledoc """
  Parallel circuits inferred from the load the network carries at rest.

  ## The finding (REVIEW CAS-26, CAS-30)

  At real demand the model cannot find an AC solution on any interconnection's
  main island, and the DC flow — which always solves — says why. Measured
  2026-09-01 at the reference hour: ERCOT has 218 rated branches over 100 %
  loading with nothing tripped, 26 over 200 %, 22,097 MW of overload in total;
  Western 135 / 18 / 12,030 MW; Eastern 335 / 34 / 37,989 MW. The worst are
  69 kV lines carrying 300–520 MW on 116 MVA ratings, 138/69 kV transformers at
  250–340 %, New York City 138 kV circuits at 900 MW each, Turkey Point's 230 kV
  tie at 1,291 MW on 402 MVA. A 69 kV line does not carry 520 MW; the real
  grid carries this load today, so a branch at several times its rating with
  nothing out of service is a MODELLING GAP — capacity the real grid has along
  that corridor and the model does not — not an overload. HIFLD carries no
  circuit count, so a double-circuit tower is one record, and every corridor
  whose parallel or higher-voltage path is missing shows up as one branch
  doing the work of several.

  ## The rule

  Solve the DC flow at a measured operating point. Every rated branch loaded
  above `threshold` (default #{"0.8"}, N-0 loading with headroom for N-1) gets
  `n = ceil(loading / threshold)` circuits: series impedance divided by `n`,
  charging and ratings multiplied by `n`. Flows redistribute, so the pass is
  iterated until no branch is over the threshold (a handful of passes). Over
  several hours the requirement is the maximum. `n` is stored on the row as
  `inferred_circuits`, the factor is FOLDED into the stored parameters exactly
  as `ParameterEstimator` folds its per-class `typical_circuits`, and every run
  starts by unfolding it, so the pass is idempotent and re-runnable after the
  network changes.

  Measured on ERCOT 2026-09-01: 404 branch-passes, 476 extra circuits on 5 % of
  branches, no branch over its rating afterwards, and the controlled AC
  ceiling moved from α 0.6 to **α 1.0** — the first AC solution at real demand
  this model has had.

  ## What it is and is not

  The capacity lands at the same voltage class and between the same buses. In
  reality the missing path is often a HIGHER class (a 69 kV line at 450 % is
  standing in for an absent 138 or 230 kV circuit between the same
  substations), so the inferred network has the right capacity in the right
  place at the wrong voltage: correct for flows and for the AC solution,
  wrong for anything that reads the class of the circuit (loss estimates,
  class censuses). `inferred_circuits > 1` marks every such row so an OSM
  circuit count or a confirmed missing line can replace the inference, and
  `at_rest_loading/2` is the census that shows how much of the network is
  carried on inferred capacity.

  A branch needing more than `max_circuits` (default #{"8"}) is left as it is and
  reported: that is not a missing parallel circuit but misplaced load or a
  missing corridor, and inferring eight circuits of 69 kV would hide it.

  ## What the rule cannot see, and the exclusion list (REVIEW EXT-1)

  A branch over its rating at rest is one of two things: capacity the model
  lacks, or a real limit the real grid operates AT — a binding constraint the
  market manages by re-dispatching generation, which this model's dispatch
  (placed by balancing authority and fuel, never asked whether a branch can
  carry it) does not do. The at-rest rule cannot tell them apart; the ISOs'
  binding-constraint records can. Measured 2026-09-01: ERCOT's two most
  frequent constraints, Frontera-S. Mission and Bruni 138 kV, read 222 % and
  204 % in the raw model and had been given three circuits each. So every
  element an ISO reports as binding (`data/vendored/known_binding_elements_*.csv`,
  produced by `scripts/score_congestion.py --emit`, keyed on HIFLD
  `source_id`) is EXCLUDED from both rules: `infer/2` reports it under
  `:real_limits` instead of giving it circuits, and `raise_ceiling/2` never
  doubles it. What relieves those branches is re-dispatch, not capacity.

  ## The second rule: pockets the at-rest test cannot see (`raise_ceiling/2`)

  With the at-rest circuits in, Western's AC still failed at α 0.4 with eleven
  buses on the solver's 0.5 pu floor and a mismatch of 0.14 MVA — one pocket
  collapsing, not a network. A 66 kV load area in the San Bernardino mountains
  (~30 MW) whose only feed in the model is a chain of 33 kV lines, 14.5 + 13.3
  + 10 km at x 0.60 + 0.55 + 0.41 pu: 30 MW at the P-V nose of 1.5 pu of
  series reactance, at 54 % MVA loading. The rating is fine; the IMPEDANCE is
  the limit, so no MW criterion can see it, and the real 66 kV feed is missing.

  `raise_ceiling/2` is ROADMAP item 2's loop automated: step α upward; when
  the controlled AC solve fails, take the buses under `@pocket_vm` in its last
  iterate as pockets (connected components), and from each pocket's DEEPEST
  bus trace a single series path outward along the largest DC inflow — through
  the pocket and beyond it — until a source: a bus whose generation can carry
  the load the path has picked up, or an EHV bus (a failed iterate's voltages
  are not an operating point, so nothing else counts as strong). Then double
  the highest-reactance branch on that path until the load it carries times
  its reactance is inside `@pocket_margin` — the radial loadability criterion,
  `S · X ≤ margin`, which is only meaningful for a series path, which is why
  the walk is one. When the criterion is already satisfied and the pocket
  still collapses, the evidence wins: one more doubling of the weakest branch.
  Re-solve; repeat. The circuits it adds carry the same `inferred_circuits`
  provenance.
  """

  import Ecto.Query

  alias PowerModel.{Demand, Grid, Repo}
  alias PowerModel.Failure.Cascade
  alias PowerModel.Grid.{Interconnection, TransmissionLine, Transformer}
  alias PowerModel.Solver.{DCPowerFlow, Partition, VoltageControl}

  require Logger

  @default_threshold 0.8
  @default_max_circuits 8
  @default_passes 8
  @base_mva 100.0

  @loading_bins [100, 150, 200, 300, 500]

  # raise_ceiling/2: a bus below this in a failed iterate is in a collapsing
  # pocket; the feeding path is traced until a generator bus; a pocket is
  # reinforced until S_path · X_path ≤ margin (pu on the solver base — 0.2
  # keeps a radial well inside its nose).
  @pocket_vm 0.7
  @pocket_vm_wide 0.85
  @pocket_margin 0.2
  @max_path_hops 25
  # A source, for the walk: a bus whose generators can carry the load the path
  # picked up, or a bus at/above this class (the EHV network).
  @source_kv 230.0
  @default_alpha_steps [0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
  @max_fixes_per_alpha 40
  # "Evidence wins" doublings a pocket (by its deepest bus) may receive after
  # the criterion is already met; past that it is declared unfixable.
  @max_forced_per_pocket 2

  @doc "Defaults, for callers that report them."
  def default_threshold, do: @default_threshold
  def default_max_circuits, do: @default_max_circuits

  # ---------------------------------------------------------------------------
  # Pure: the rule on a snapshot
  # ---------------------------------------------------------------------------

  @doc """
  Infer parallel circuits on a snapshot (one island or a whole network with
  `Partition`-separable islands) at its own dispatch. Pure.

  Returns `{snapshot, report}` where the snapshot's lines and transformers
  carry updated `r_pu`/`x_pu`/`b_pu`/ratings and an `:inferred_circuits`
  count (relative to the snapshot as given), and the report lists every
  branch touched.

  Options: `:threshold`, `:max_circuits`, `:passes`, `:base_mva`, `:exclude`
  (a `MapSet` of `{:line | :transformer, id}` never given circuits; default
  `known_binding_elements(snapshot)`).
  """
  def infer(snapshot, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    max_circuits = Keyword.get(opts, :max_circuits, @default_max_circuits)
    passes = Keyword.get(opts, :passes, @default_passes)
    base_mva = Keyword.get(opts, :base_mva, @base_mva)
    exclude = Keyword.get_lazy(opts, :exclude, fn -> known_binding_elements(snapshot) end)

    {snapshot, circuits, over_cap, pass_log} =
      Enum.reduce_while(1..passes, {snapshot, %{}, %{}, []}, fn pass,
                                                                {snap, circuits, over_cap, log} ->
        solution = DCPowerFlow.solve_islands(snap, base_mva: base_mva)

        needs =
          solution.line_flows
          |> Enum.filter(fn {_key, f} -> rated?(f) and f.loading_pct > threshold * 100.0 end)
          |> Map.new(fn {key, f} -> {key, ceil(f.loading_pct / (threshold * 100.0) - 1.0e-9)} end)

        # A reported real limit is not given capacity, however loaded.
        {real, needs} = Enum.split_with(needs, fn {key, _n} -> MapSet.member?(exclude, key) end)

        over_cap =
          Enum.reduce(real, over_cap, fn {key, _}, acc -> Map.put_new(acc, key, :real_limit) end)

        {apply_now, refused} =
          Enum.split_with(needs, fn {key, n} -> Map.get(circuits, key, 1) * n <= max_circuits end)

        over_cap = Enum.reduce(refused, over_cap, fn {key, n}, acc -> Map.put(acc, key, n) end)

        if apply_now == [] do
          {:halt, {snap, circuits, over_cap, [{pass, 0, 0} | log]}}
        else
          snap = Enum.reduce(apply_now, snap, fn {key, n}, s -> multiply_branch(s, key, n) end)

          circuits =
            Enum.reduce(apply_now, circuits, fn {key, n}, acc ->
              Map.update(acc, key, n, &(&1 * n))
            end)

          extra = Enum.reduce(apply_now, 0, fn {_, n}, acc -> acc + n - 1 end)
          {:cont, {snap, circuits, over_cap, [{pass, length(apply_now), extra} | log]}}
        end
      end)

    {real_limits, over_cap} =
      Enum.split_with(over_cap, fn {_key, v} -> v == :real_limit end)

    report = %{
      threshold: threshold,
      max_circuits: max_circuits,
      branches: map_size(circuits),
      extra_circuits: circuits |> Map.values() |> Enum.map(&(&1 - 1)) |> Enum.sum(),
      circuits: circuits,
      over_cap: Map.new(over_cap),
      real_limits: Enum.map(real_limits, &elem(&1, 0)),
      passes: Enum.reverse(pass_log)
    }

    {stamp_circuits(snapshot, circuits), report}
  end

  defp rated?(f), do: is_number(f.rating_mva) and f.rating_mva > 0.0

  @known_binding_glob "data/vendored/known_binding_elements_*.csv"

  @doc """
  The branches an ISO reports as binding, as `{:line | :transformer, id}` keys
  resolved against this snapshot (lines by HIFLD `source_id`, transformers by
  row id). Empty when no record is vendored. See the moduledoc.
  """
  def known_binding_elements(snapshot, paths \\ Path.wildcard(@known_binding_glob)) do
    rows =
      paths
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.drop(1)
        |> Enum.map(&String.split(&1, ","))
      end)

    by_source_id =
      Map.new(snapshot.lines, fn l -> {to_string(Map.get(l, :source_id) || ""), l.id} end)

    Enum.reduce(rows, MapSet.new(), fn
      [_iso, _label, _n, branch_id, source_id | _], acc ->
        cond do
          String.starts_with?(branch_id, "T") ->
            MapSet.put(
              acc,
              {:transformer, String.to_integer(String.trim_leading(branch_id, "T"))}
            )

          source_id != "" and Map.has_key?(by_source_id, source_id) ->
            MapSet.put(acc, {:line, Map.fetch!(by_source_id, source_id)})

          true ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  # Multiply a branch's circuit count by n: series impedance / n, shunt and
  # ratings × n.
  defp multiply_branch(snapshot, {:line, id}, n) do
    %{
      snapshot
      | lines: Enum.map(snapshot.lines, &if(&1.id == id, do: scale_line(&1, n), else: &1))
    }
  end

  defp multiply_branch(snapshot, {:transformer, id}, n) do
    %{
      snapshot
      | transformers:
          Enum.map(
            snapshot.transformers,
            &if(&1.id == id, do: scale_transformer(&1, n), else: &1)
          )
    }
  end

  @doc "A line's parameters with its circuit count multiplied by `n`. Pure."
  def scale_line(line, n) when is_integer(n) and n >= 1 do
    line
    |> Map.put(:r_pu, div_or_nil(Map.get(line, :r_pu), n))
    |> Map.put(:x_pu, div_or_nil(Map.get(line, :x_pu), n))
    |> Map.put(:b_pu, mul_or_nil(Map.get(line, :b_pu), n))
    |> Map.put(:rating_a_mva, mul_or_nil(Map.get(line, :rating_a_mva), n))
    |> Map.put(:rating_b_mva, mul_or_nil(Map.get(line, :rating_b_mva), n))
    |> Map.put(:rating_c_mva, mul_or_nil(Map.get(line, :rating_c_mva), n))
  end

  @doc "A transformer's parameters with its circuit (bank) count multiplied by `n`. Pure."
  def scale_transformer(xfmr, n) when is_integer(n) and n >= 1 do
    xfmr
    |> Map.put(:r_pu, div_or_nil(Map.get(xfmr, :r_pu), n))
    |> Map.put(:x_pu, div_or_nil(Map.get(xfmr, :x_pu), n))
    |> Map.put(:rated_mva, mul_or_nil(Map.get(xfmr, :rated_mva), n))
  end

  defp div_or_nil(v, n) when is_number(v), do: v / n
  defp div_or_nil(_, _), do: nil
  defp mul_or_nil(v, n) when is_number(v), do: v * n
  defp mul_or_nil(_, _), do: nil

  defp stamp_circuits(snapshot, circuits) do
    %{
      snapshot
      | lines:
          Enum.map(snapshot.lines, fn l ->
            Map.put(l, :inferred_circuits, Map.get(circuits, {:line, l.id}, 1))
          end),
        transformers:
          Enum.map(snapshot.transformers, fn t ->
            Map.put(t, :inferred_circuits, Map.get(circuits, {:transformer, t.id}, 1))
          end)
    }
  end

  @doc """
  How the network is loaded at rest: the DC flow of a snapshot at its own
  dispatch, summarised. Pure.

      %{rated: n, over: %{100 => n, 150 => n, ...}, overload_mw: mw,
        worst: [%{branch:, loading_pct:, flow_mw:, rating_mva:}], by_class: %{kv => n}}
  """
  def at_rest_loading(snapshot, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, @base_mva)
    limit = Keyword.get(opts, :limit, 10)
    solution = DCPowerFlow.solve_islands(snapshot, base_mva: base_mva)
    flows = Enum.filter(solution.line_flows, fn {_k, f} -> rated?(f) end)
    kv_of = branch_kv(snapshot)

    over =
      Map.new(@loading_bins, fn b ->
        {b, Enum.count(flows, fn {_, f} -> f.loading_pct > b end)}
      end)

    %{
      rated: length(flows),
      over: over,
      overload_mw:
        flows
        |> Enum.map(fn {_, f} -> max(abs(f.p_flow_mw) - f.rating_mva, 0.0) end)
        |> Enum.sum(),
      worst:
        flows
        |> Enum.sort_by(fn {_, f} -> -f.loading_pct end)
        |> Enum.take(limit)
        |> Enum.map(fn {key, f} ->
          %{
            branch: key,
            loading_pct: f.loading_pct,
            flow_mw: f.p_flow_mw,
            rating_mva: f.rating_mva
          }
        end),
      by_class:
        flows
        |> Enum.filter(fn {_, f} -> f.loading_pct > 100.0 end)
        |> Enum.frequencies_by(fn {key, _} -> Map.get(kv_of, key) end)
    }
  end

  defp branch_kv(snapshot) do
    bus_kv = Map.new(snapshot.buses, &{&1.id, &1.base_kv})

    # A line's own class when it carries one; the higher endpoint bus otherwise.
    lines =
      Map.new(snapshot.lines, fn l ->
        kv =
          Map.get(l, :voltage_kv) ||
            max(Map.get(bus_kv, l.from_bus_id) || 0.0, Map.get(bus_kv, l.to_bus_id) || 0.0)

        {{:line, l.id}, kv}
      end)

    xfmrs =
      Map.new(snapshot.transformers, fn t ->
        {{:transformer, t.id},
         {:xfmr, max(Map.get(bus_kv, t.from_bus_id) || 0.0, Map.get(bus_kv, t.to_bus_id) || 0.0)}}
      end)

    Map.merge(lines, xfmrs)
  end

  # ---------------------------------------------------------------------------
  # Pockets: the AC-driven loop
  # ---------------------------------------------------------------------------

  @doc """
  Raise an island's controlled AC ceiling toward `:target` by reinforcing the
  feeding paths of the pockets that collapse (see the moduledoc). Pure.

  Returns `{island, report}`: the island with circuits folded in and
  `:inferred_circuits` stamped (relative to the island as given), and

      %{ceiling: α, target: α, circuits: %{key => n}, fixes: [%{alpha:, pocket_buses:,
        pocket_mw:, path: [key], before: S·X, after: S·X}], unfixable: [...]}

  Options: `:target` (default 1.0), `:alpha_steps`, `:margin`, `:max_circuits`,
  `:peak_multiplier`, `:base_mva`, plus solver options.
  """
  def raise_ceiling(island, opts \\ []) do
    target = Keyword.get(opts, :target, 1.0)
    steps = Keyword.get(opts, :alpha_steps, @default_alpha_steps) |> Enum.filter(&(&1 <= target))
    margin = Keyword.get(opts, :margin, @pocket_margin)
    max_circuits = Keyword.get(opts, :max_circuits, @default_max_circuits)
    base_mva = Keyword.get(opts, :base_mva, @base_mva)
    peak = Keyword.get(opts, :peak_multiplier, 1.75)

    solve_opts = [
      base_mva: base_mva,
      dense_nr_max_buses: Keyword.get(opts, :dense_nr_max_buses, 0),
      max_iterations: Keyword.get(opts, :max_iterations, 400)
    ]

    # The cap counts what is already stored on the row plus what this run adds.
    stored =
      Map.new(
        Enum.map(island.lines, &{{:line, &1.id}, Map.get(&1, :inferred_circuits) || 1}) ++
          Enum.map(
            island.transformers,
            &{{:transformer, &1.id}, Map.get(&1, :inferred_circuits) || 1}
          )
      )

    acc0 = %{
      island: island,
      circuits: %{},
      stored: stored,
      exclude: Keyword.get_lazy(opts, :exclude, fn -> known_binding_elements(island) end),
      fixes: [],
      unfixable: [],
      ceiling: 0.0,
      carry: nil,
      stopped: nil,
      # deepest bus => forced doublings so far; unfixable pockets are skipped
      forced: %{},
      given_up: MapSet.new()
    }

    acc =
      Enum.reduce_while(steps, acc0, fn a, acc ->
        case climb(a, acc, solve_opts, margin, max_circuits, base_mva, peak, 0) do
          {:ok, acc} -> {:cont, %{acc | ceiling: a}}
          {:stuck, acc} -> {:halt, acc}
        end
      end)

    report = %{
      ceiling: acc.ceiling,
      target: target,
      circuits: acc.circuits,
      branches: map_size(acc.circuits),
      extra_circuits: acc.circuits |> Map.values() |> Enum.map(&(&1 - 1)) |> Enum.sum(),
      fixes: Enum.reverse(acc.fixes),
      unfixable: Enum.reverse(acc.unfixable),
      stopped: acc.stopped
    }

    {stamp_circuits(acc.island, acc.circuits), report}
  end

  # Solve at α; on failure, fix the pockets and try again, up to the per-α cap.
  defp climb(a, acc, solve_opts, margin, max_circuits, base_mva, peak, n_fixes) do
    scaled = scale_island(acc.island, a)
    devices = VoltageControl.devices(scaled, peak_multiplier: peak)

    opts =
      solve_opts ++
        [devices: devices] ++
        case acc.carry do
          %{state: st, warm: w} -> [control_state: st, warm_start: w]
          _ -> []
        end

    sol =
      try do
        {:ok, s} = VoltageControl.solve(scaled, opts)
        s
      catch
        _, _ -> nil
      end

    cond do
      sol && sol.converged ->
        {:ok, %{acc | carry: %{state: sol.voltage_control.state, warm: sol}}}

      n_fixes >= @max_fixes_per_alpha ->
        {:stuck, %{acc | stopped: %{alpha: a, reason: :fix_cap, fixes: n_fixes}}}

      true ->
        v = if sol, do: Enum.zip(sol.bus_ids, sol.vm_pu) |> Map.new(), else: %{}

        pockets =
          scaled
          |> pockets(v)
          |> Enum.reject(fn pocket -> MapSet.member?(acc.given_up, deepest_bus(pocket, v)) end)

        if pockets == [] do
          vm_min = if v == %{}, do: nil, else: v |> Map.values() |> Enum.min()

          {:stuck,
           %{acc | stopped: %{alpha: a, reason: :no_pockets, vm_min: vm_min, solved: sol != nil}}}
        else
          dc = DCPowerFlow.solve(scaled, base_mva: base_mva)

          {acc, fixed_any} =
            Enum.reduce(pockets, {acc, false}, fn pocket, {acc, fixed_any} ->
              case reinforce(acc, scaled, pocket, v, dc, a, margin, max_circuits, base_mva) do
                {:fixed, acc} -> {acc, true}
                {:unfixable, acc} -> {acc, fixed_any}
              end
            end)

          if fixed_any,
            do: climb(a, acc, solve_opts, margin, max_circuits, base_mva, peak, n_fixes + 1),
            else:
              {:stuck,
               %{acc | stopped: %{alpha: a, reason: :unfixable, pockets: length(pockets)}}}
        end
    end
  end

  defp deepest_bus(pocket, v), do: Enum.min_by(pocket, &Map.get(v, &1, 1.0))

  defp scale_island(island, a) do
    %{
      island
      | loads:
          Enum.map(
            island.loads,
            &%{&1 | p_mw: (&1.p_mw || 0.0) * a, q_mvar: (&1.q_mvar || 0.0) * a}
          ),
        generators: Enum.map(island.generators, &%{&1 | p_max_mw: &1.p_max_mw * a})
    }
  end

  # Connected components of the buses under @pocket_vm — or, when the failed
  # iterate has none that deep, under @pocket_vm_wide — each as a MapSet.
  defp pockets(island, v) do
    low_at = fn t ->
      v |> Enum.filter(fn {_b, vm} -> vm < t end) |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    end

    low = low_at.(@pocket_vm)
    low = if MapSet.size(low) == 0, do: low_at.(@pocket_vm_wide), else: low
    adj = adjacency(island)

    {components, _seen} =
      Enum.reduce(low, {[], MapSet.new()}, fn b, {comps, seen} ->
        if MapSet.member?(seen, b) do
          {comps, seen}
        else
          comp = flood(b, low, adj)
          {[comp | comps], MapSet.union(seen, comp)}
        end
      end)

    components
  end

  defp adjacency(island) do
    Enum.reduce(island.lines ++ island.transformers, %{}, fn br, acc ->
      acc
      |> Map.update(br.from_bus_id, [br.to_bus_id], &[br.to_bus_id | &1])
      |> Map.update(br.to_bus_id, [br.from_bus_id], &[br.from_bus_id | &1])
    end)
  end

  defp flood(start, allowed, adj) do
    do_flood([start], MapSet.new([start]), allowed, adj)
  end

  defp do_flood([], seen, _allowed, _adj), do: seen

  defp do_flood([b | rest], seen, allowed, adj) do
    next =
      adj
      |> Map.get(b, [])
      |> Enum.filter(&(MapSet.member?(allowed, &1) and not MapSet.member?(seen, &1)))

    do_flood(rest ++ next, Enum.reduce(next, seen, &MapSet.put(&2, &1)), allowed, adj)
  end

  # Trace the pocket's feeding path and double its weakest branches until the
  # radial loadability criterion holds.
  defp reinforce(acc, island, pocket, v, dc, a, margin, max_circuits, base_mva) do
    branches = index_branches(island)

    gen_mw =
      Enum.reduce(island.generators, %{}, fn g, acc ->
        Map.update(acc, g.bus_id, g.p_max_mw || 0.0, &(&1 + (g.p_max_mw || 0.0)))
      end)

    load_mw =
      Enum.reduce(island.loads, %{}, fn l, acc ->
        Map.update(acc, l.bus_id, l.p_mw || 0.0, &(&1 + (l.p_mw || 0.0)))
      end)

    bus_kv = Map.new(island.buses, &{&1.id, &1.base_kv || 0.0})

    # A source carries the load, so a bus with no generation is never one and
    # a walk that has picked up nothing yet cannot stop at the first machine.
    source? = fn bus, carried ->
      Map.get(gen_mw, bus, 0.0) >= max(carried, 1.0) or
        Map.get(bus_kv, bus, 0.0) >= @source_kv
    end

    # One series path from the pocket's deepest bus to a source, carrying the
    # whole pocket's load from the start.
    pocket_mw = pocket |> Enum.map(&Map.get(load_mw, &1, 0.0)) |> Enum.sum()
    deepest = Enum.min_by(pocket, &Map.get(v, &1, 1.0))

    {path, walked} =
      feeding_path(MapSet.new([deepest]), branches, dc, source?, load_mw, pocket_mw)

    # The load the path carries: the pocket's, plus what the walk picked up
    # outside it on the way to the source.
    carried = MapSet.union(pocket, walked)

    {p, q} =
      Enum.reduce(island.loads, {0.0, 0.0}, fn l, {p, q} ->
        if MapSet.member?(carried, l.bus_id),
          do: {p + (l.p_mw || 0.0), q + (l.q_mvar || 0.0)},
          else: {p, q}
      end)

    s_pu = :math.sqrt(p * p + q * q) / base_mva

    x_of = fn key ->
      {_, br} = Map.fetch!(branches, key)
      abs(br.x_pu || 0.0)
    end

    x_path = path |> Enum.map(x_of) |> Enum.sum()

    # Greedy: double the highest-reactance branch on the path until inside the
    # margin, or until every branch is at the cap. If the criterion is already
    # met and the pocket still collapses, the evidence wins — a bounded number
    # of times per pocket.
    forced_so_far = Map.get(acc.forced, deepest, 0)

    # Effective counts for the cap: stored on the row times added by this run.
    effective =
      Map.new(path, fn key ->
        {key, Map.get(acc.stored, key, 1) * Map.get(acc.circuits, key, 1)}
      end)

    {doublings, x_after, forced} =
      case greedy_doublings(path, x_of, effective, s_pu, x_path, margin, max_circuits) do
        {d, x} when d == %{} and path != [] and forced_so_far < @max_forced_per_pocket ->
          # One doubling: a margin just under the current S·X forces exactly
          # the largest-reactance branch to halve.
          {d2, x2} =
            greedy_doublings(
              path,
              x_of,
              effective,
              s_pu,
              x_path,
              s_pu * x_path * 0.99,
              max_circuits
            )

          if d2 == %{}, do: {d, x, false}, else: {d2, x2, true}

        {d, x} ->
          {d, x, false}
      end

    acc = if forced, do: %{acc | forced: Map.update(acc.forced, deepest, 1, &(&1 + 1))}, else: acc

    if doublings == %{} do
      {:unfixable,
       %{
         acc
         | given_up: MapSet.put(acc.given_up, deepest),
           unfixable: [
             %{
               alpha: a,
               pocket_buses: MapSet.size(pocket),
               pocket_mw: p,
               path: path,
               s_x: s_pu * x_path
             }
             | acc.unfixable
           ]
       }}
    else
      island2 =
        Enum.reduce(doublings, acc.island, fn {key, k}, isl -> multiply_branch(isl, key, k) end)

      circuits =
        Enum.reduce(doublings, acc.circuits, fn {key, k}, c ->
          Map.update(c, key, k, &(&1 * k))
        end)

      {:fixed,
       %{
         acc
         | island: island2,
           circuits: circuits,
           fixes: [
             %{
               alpha: a,
               pocket_buses: MapSet.size(pocket),
               pocket_mw: p,
               path: path,
               doublings: doublings,
               before: s_pu * x_path,
               after: s_pu * x_after
             }
             | acc.fixes
           ]
       }}
    end
  end

  defp greedy_doublings(path, x_of, circuits, s_pu, x_path, margin, max_circuits) do
    xs = Map.new(path, &{&1, x_of.(&1)})
    do_greedy(xs, %{}, circuits, s_pu, x_path, margin, max_circuits)
  end

  defp do_greedy(xs, doublings, circuits, s_pu, x_path, margin, max_circuits) do
    if s_pu * x_path <= margin or xs == %{} do
      {doublings, x_path}
    else
      candidates =
        Enum.reject(xs, fn {key, _x} ->
          Map.get(circuits, key, 1) * Map.get(doublings, key, 1) * 2 > max_circuits
        end)

      case candidates do
        [] ->
          {doublings, x_path}

        _ ->
          {key, x} = Enum.max_by(candidates, &elem(&1, 1))
          xs = Map.put(xs, key, x / 2)
          doublings = Map.update(doublings, key, 2, &(&1 * 2))
          do_greedy(xs, doublings, circuits, s_pu, x_path - x / 2, margin, max_circuits)
      end
    end
  end

  defp index_branches(island) do
    lines = Map.new(island.lines, &{{:line, &1.id}, {:line, &1}})
    xfmrs = Map.new(island.transformers, &{{:transformer, &1.id}, {:transformer, &1}})
    Map.merge(lines, xfmrs)
  end

  # Walk outward from the pocket along the largest DC inflow until a source —
  # a bus whose generation can carry the load picked up so far, or an EHV bus
  # — or the hop cap. Returns `{branch keys walked, buses walked}`.
  defp feeding_path(pocket, branches, dc, source?, load_mw, carried_mw) do
    do_path(pocket, branches, dc, source?, load_mw, carried_mw, [], MapSet.new(), 0)
  end

  defp do_path(_set, _b, _dc, _s, _l, _c, path, walked, hops) when hops >= @max_path_hops,
    do: {Enum.reverse(path), walked}

  defp do_path(set, branches, dc, source?, load_mw, carried, path, walked, hops) do
    best =
      branches
      |> Enum.flat_map(fn {key, {_t, br}} ->
        fi = MapSet.member?(set, br.from_bus_id)
        ti = MapSet.member?(set, br.to_bus_id)

        case {fi, ti} do
          {true, false} ->
            flow = dc.line_flows[key][:p_flow_mw] || 0.0
            [{-flow, key, br.to_bus_id}]

          {false, true} ->
            flow = dc.line_flows[key][:p_flow_mw] || 0.0
            [{flow, key, br.from_bus_id}]

          _ ->
            []
        end
      end)
      |> Enum.max_by(&elem(&1, 0), fn -> nil end)

    case best do
      nil ->
        {Enum.reverse(path), walked}

      {_inflow, key, outside} ->
        path = [key | path]
        carried = carried + Map.get(load_mw, outside, 0.0)

        if source?.(outside, carried) do
          {Enum.reverse(path), walked}
        else
          do_path(
            MapSet.put(set, outside),
            branches,
            dc,
            source?,
            load_mw,
            carried,
            path,
            MapSet.put(walked, outside),
            hops + 1
          )
        end
    end
  end

  # ---------------------------------------------------------------------------
  # The database pass
  # ---------------------------------------------------------------------------

  @doc """
  Infer and WRITE parallel circuits for every interconnection (or `:names`).

  The operating point is the measured dispatch at each hour in `:hours`
  (default: the peak demand hour in the ingested record and the latest one —
  the capacity a grid is built for, and the hour everything else here is
  measured at), with the fossil fleet pinned to its measured CEMS operation
  wherever the vendored day covers the hour (`cems: false` to opt out; hours
  outside the vendored day degrade to the BA-fuel merit fill on their own).
  Deriving capacity at one operating point and simulating at another let the
  passes unfold circuits the measured flows need (CAS-32's re-map exposed
  this: two Permian 69 kV lines lost their 5 inferred circuits because the
  BA-fuel at-rest flows stayed under 80 % where the measured flows carry
  750 MW); a branch gets the largest count any hour asks for. The dispatch
  is then shifted until no overload a generation shift can relieve remains
  (`Dispatch.Redispatch`; `redispatch: false` to opt out), so only what
  re-dispatch cannot fix is read as missing capacity — the distinction EXT-1
  showed the at-rest rule needs, made the DEFAULT once CAS-32 measured what
  skipping it costs: at the measured operating point the at-rest rule reads
  the stress AROUND real constraints as missing capacity and inflates their
  parallel paths, which no exclusion list can guard (ERCOT's found-element
  median fell 46 % → 41 % without it, and the shift costs under a minute
  even on Eastern). The pass first UNFOLDS the circuits a
  previous run stored, so it is idempotent and can be re-run after any change
  to the network.

  Returns `%{name => report}`.
  """
  def run(opts \\ []) do
    hours = Keyword.get_lazy(opts, :hours, &default_hours/0)
    names = Keyword.get(opts, :names)

    interconnections =
      case names do
        nil -> Repo.all(from(i in Interconnection, order_by: i.name))
        names -> Enum.map(names, &Repo.get_by!(Interconnection, name: &1))
      end

    Map.new(interconnections, fn ic ->
      {ic.name, run_interconnection(ic, hours, opts)}
    end)
  end

  defp default_hours do
    [Demand.peak_demand_hour(), Demand.latest_demand_hour()]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp run_interconnection(ic, hours, opts) do
    # The requirement is computed from single-circuit parameters: unfold what
    # a previous run stored before measuring.
    unfold_stored(ic.id)

    requirements =
      Enum.reduce(hours, %{}, fn hour, acc ->
        snap = Grid.get_grid_snapshot(ic.id, hour: hour)
        state = Cascade.init(snap, @base_mva, hour: hour, cems: Keyword.get(opts, :cems, true))

        {subs, _dead} =
          Partition.split(%{
            buses: state.buses,
            lines: state.lines,
            transformers: state.transformers,
            generators: Cascade.dispatched_generators(state),
            loads: state.loads
          })

        Enum.reduce(subs, acc, fn island, acc ->
          # `redispatch: true` — relieve every overload a generation shift
          # can before reading what is left as missing capacity (EXT-1).
          island =
            if Keyword.get(opts, :redispatch, true) == true,
              do:
                island |> PowerModel.Dispatch.Redispatch.relieve(base_mva: @base_mva) |> elem(0),
              else: island

          {_snap, report} = infer(island, opts)

          if report.over_cap != %{} do
            Logger.warning(
              "capacity inference #{ic.name} #{hour}: #{map_size(report.over_cap)} branch(es) would need " <>
                "more than #{report.max_circuits} circuits and were left alone: " <>
                inspect(Enum.take(report.over_cap, 8))
            )
          end

          Enum.reduce(report.circuits, acc, fn {key, n}, a ->
            Map.update(a, key, n, &max(&1, n))
          end)
        end)
      end)

    written = write_circuits(requirements, :absolute)

    Logger.info(
      "capacity inference #{ic.name}: #{written} branches given " <>
        "#{requirements |> Map.values() |> Enum.map(&(&1 - 1)) |> Enum.sum()} extra circuits " <>
        "over #{length(hours)} hour(s)"
    )

    %{
      branches: written,
      extra_circuits: requirements |> Map.values() |> Enum.map(&(&1 - 1)) |> Enum.sum(),
      circuits: requirements
    }
  end

  # Divide the stored parameters back to one circuit for every row of this
  # interconnection that carries an inferred count.
  defp unfold_stored(ic_id) do
    Repo.update_all(
      from(l in TransmissionLine,
        join: b in assoc(l, :from_bus),
        where: b.interconnection_id == ^ic_id and l.inferred_circuits > 1,
        update: [
          set: [
            r_pu: l.r_pu * l.inferred_circuits,
            x_pu: l.x_pu * l.inferred_circuits,
            b_pu: l.b_pu / l.inferred_circuits,
            rating_a_mva: l.rating_a_mva / l.inferred_circuits,
            rating_b_mva: l.rating_b_mva / l.inferred_circuits,
            rating_c_mva: l.rating_c_mva / l.inferred_circuits,
            inferred_circuits: 1
          ]
        ]
      ),
      []
    )

    Repo.update_all(
      from(t in Transformer,
        join: b in assoc(t, :from_bus),
        where: b.interconnection_id == ^ic_id and t.inferred_circuits > 1,
        update: [
          set: [
            r_pu: t.r_pu * t.inferred_circuits,
            x_pu: t.x_pu * t.inferred_circuits,
            rated_mva: t.rated_mva / t.inferred_circuits,
            inferred_circuits: 1
          ]
        ]
      ),
      []
    )

    :ok
  end

  # `:absolute` sets the count (the caller unfolded first); `:multiply` folds a
  # further factor onto whatever is stored.
  defp write_circuits(requirements, mode) do
    Enum.reduce(requirements, 0, fn
      {{:line, id}, n}, acc when n > 1 ->
        f = n * 1.0

        Repo.update_all(
          from(l in TransmissionLine,
            where: l.id == ^id,
            update: [
              set: [
                r_pu: l.r_pu / ^f,
                x_pu: l.x_pu / ^f,
                b_pu: l.b_pu * ^f,
                rating_a_mva: l.rating_a_mva * ^f,
                rating_b_mva: l.rating_b_mva * ^f,
                rating_c_mva: l.rating_c_mva * ^f,
                inferred_circuits:
                  fragment(
                    "CASE WHEN ? THEN ? ELSE inferred_circuits * ? END",
                    ^(mode == :absolute),
                    ^n,
                    ^n
                  )
              ]
            ]
          ),
          []
        )

        acc + 1

      {{:transformer, id}, n}, acc when n > 1 ->
        f = n * 1.0

        Repo.update_all(
          from(t in Transformer,
            where: t.id == ^id,
            update: [
              set: [
                r_pu: t.r_pu / ^f,
                x_pu: t.x_pu / ^f,
                rated_mva: t.rated_mva * ^f,
                inferred_circuits:
                  fragment(
                    "CASE WHEN ? THEN ? ELSE inferred_circuits * ? END",
                    ^(mode == :absolute),
                    ^n,
                    ^n
                  )
              ]
            ]
          ),
          []
        )

        acc + 1

      _, acc ->
        acc
    end)
  end

  @doc """
  Run the pocket loop (`raise_ceiling/2`) on every interconnection's main
  island at `:hour` (default: the latest ingested hour, where the census
  measures) and WRITE the circuits it adds on top of what is stored. Not
  idempotent in the sense of `run/1` — it adds capacity only where the AC
  solve still fails, so a second run on a network that already reaches the
  target adds nothing.

  Returns `%{name => report}` with the ceiling reached and what was written.
  """
  def run_ceiling(opts \\ []) do
    hour = Keyword.get_lazy(opts, :hour, &Demand.latest_demand_hour/0)
    names = Keyword.get(opts, :names)

    interconnections =
      case names do
        nil -> Repo.all(from(i in Interconnection, order_by: i.name))
        names -> Enum.map(names, &Repo.get_by!(Interconnection, name: &1))
      end

    Map.new(interconnections, fn ic ->
      snap = Grid.get_grid_snapshot(ic.id, hour: hour)
      state = Cascade.init(snap, @base_mva, hour: hour, cems: Keyword.get(opts, :cems, true))

      {subs, _dead} =
        Partition.split(%{
          buses: state.buses,
          lines: state.lines,
          transformers: state.transformers,
          generators: Cascade.dispatched_generators(state),
          loads: state.loads
        })

      case subs do
        [] ->
          {ic.name, %{ceiling: nil, branches: 0, extra_circuits: 0}}

        _ ->
          island = Enum.max_by(subs, &length(&1.buses))
          {_island, report} = raise_ceiling(island, opts)
          written = write_circuits(report.circuits, :multiply)

          Logger.info(
            "capacity inference (pockets) #{ic.name}: ceiling #{report.ceiling} of #{report.target}; " <>
              "#{written} branches given #{report.extra_circuits} extra circuits over " <>
              "#{length(report.fixes)} pocket fixes (#{length(report.unfixable)} unfixable)"
          )

          {ic.name, Map.put(report, :written, written)}
      end
    end)
  end

  @doc "How many branches carry inferred circuits, and how many extra circuits, per interconnection."
  def stored_summary do
    lines =
      from(l in TransmissionLine,
        join: b in assoc(l, :from_bus),
        join: i in assoc(b, :interconnection),
        where: l.inferred_circuits > 1,
        group_by: i.name,
        select: {i.name, count(l.id), sum(l.inferred_circuits - 1)}
      )
      |> Repo.all()

    xfmrs =
      from(t in Transformer,
        join: b in assoc(t, :from_bus),
        join: i in assoc(b, :interconnection),
        where: t.inferred_circuits > 1,
        group_by: i.name,
        select: {i.name, count(t.id), sum(t.inferred_circuits - 1)}
      )
      |> Repo.all()

    (lines ++ xfmrs)
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {name, rows} ->
      {name,
       %{
         branches: Enum.sum(Enum.map(rows, &elem(&1, 1))),
         extra_circuits: Enum.sum(Enum.map(rows, &(elem(&1, 2) || 0)))
       }}
    end)
  end
end
