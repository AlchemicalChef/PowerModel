defmodule PowerModel.Solver.LODF do
  @moduledoc """
  Line Outage Distribution Factors: exact DC flow updates for branch outages,
  from one factorization of B'.

  Tripping branch `k` moves its flow onto the rest of the network. In the DC
  approximation that redistribution is *linear and exact*, so it can be had
  without re-solving:

      f_l_new = f_l + LODF[l,k] * f_k

  where, writing `x = B'^-1 (e_a - e_b)` for the outaged branch's endpoints
  `a`, `b` (one sparse back-substitution),

      PTDF[l,k] = b_l * (x[from_l] - x[to_l])
      LODF[l,k] = PTDF[l,k] / (1 - PTDF[k,k])

  One cached back-substitution replaces a full re-solve — measured on the
  Eastern interconnection, ~3.7 ms against ~404 ms — which is what makes
  screening every branch in the system tractable
  (`PowerModel.Analysis.ContingencyScreening`).

  ## Multiple outages are exact too, and not by compounding

  Removing a set `K` of branches is a rank-`|K|` update to B', so Woodbury
  gives the answer exactly — there is no need to apply single-outage LODFs one
  after another, and doing so is *wrong* after the first trip (each factor was
  derived for the intact network). This module therefore never compounds. It
  keeps the outage set, and every query recomputes from the ORIGINAL base flows
  via the multi-outage identity:

      Psi[i][j] = b_i * (x_j[from_i] - x_j[to_i])       (|K| x |K|)
      (I - Psi) y = f_K                                 (small dense solve)
      delta_f_l  = sum_j b_l * (x_j[from_l] - x_j[to_l]) * y_j

  For `|K| = 1` this collapses to the familiar single-outage formula above.
  Adding a trip costs one more sensitivity solve plus an O(|K|^3) dense solve
  on a matrix small enough to write on a napkin.

  ## What actually bounds validity

  The trip count is not the interesting limit; three other things are.

    * **Islanding.** When the outage set disconnects the network, `I - Psi` is
      singular (for `|K| = 1`, `1 - PTDF[k,k] = 0`) and no flow update exists.
      Bridges of the intact graph are found once at `init/3` by a DFS
      (Tarjan low-link), so those outages are answered as
      `{:island_split, ...}` without a solve at all, with the load, generation
      and bus count of the side that loses the slack attached. The
      singular-matrix test
      remains as the numerical backstop and catches splits that only appear
      after earlier trips.
    * **Changed injections.** LODF holds the bus injection vector fixed. The
      moment a cascade redispatches, sheds load, or trips a generator, the
      base flows this module extrapolates from are stale and the result is an
      approximation of unknown quality. Nothing here can detect that; the
      caller must re-solve. This is why the full DC solve stays authoritative
      and LODF only screens and ranks.
    * **Conditioning.** The dense `I - Psi` solve degrades as `|K|` grows and
      the outaged branches interact. `:max_outages` (16 by default) is a
      refuse-rather-than-degrade horizon: past it, `trip_line/2` returns
      `{:error, state, {:validity_horizon_exceeded, k, max}}` instead of an
      answer nobody checked.

  ## Conventions are pinned to the DC solver, not re-derived

  LODF flows are only comparable to solved flows if B' is assembled the same
  way. This module uses `YBus.effective_reactance/1` (sign-preserving +/-1e-3
  floor) and the symmetric transformer entry `b = 1/(t * x)`, matching
  `DCPowerFlow.b_prime_triplets/3` exactly. Rather than trust that by
  inspection, `init/3` recomputes every branch flow from the base solution's
  own angles and refuses to build a state whose flows disagree with the
  solution it was handed — convention drift shows up as an `init` error, not
  as quietly wrong screening.

  ## Scope

  `init/3` expects ONE connected island (what `Grid.get_grid_snapshot/2` and
  `Partition.split/2` produce). A disconnected snapshot has a singular B' and
  is refused with `{:error, {:disconnected, component_count}}`.

  ## Usage

      {:ok, lodf} = LODF.init(snapshot, base_solution)
      {:ok, lodf, flows} = LODF.trip_line(lodf, {:line, 42})
      {:island_split, lodf, info} = LODF.trip_line(lodf, {:line, 7})
  """

  require Logger

  alias PowerModel.Grid.Ratings
  alias PowerModel.Solver.{Sparse, YBus}

  defstruct [
    # bus count in the island
    :n,
    # B' dimension, n - 1
    :size,
    # index of the slack bus in the snapshot's bus ordering
    :slack_idx,
    # %{bus_id => index}
    :bus_index,
    :base_mva,
    # ResourceArc handle for the cached LDL^T factorization of B'
    :handle,
    # tuple of branch records, position-indexed
    :branches,
    # %{branch_key => position}
    :pos_by_key,
    # tuple of base flows in MW, position-indexed
    :base_flow_mw,
    # scan list: {pos, from_red, to_red, b, base_flow_mw, rate_a, base_overload_mw}
    # for RATED branches only (an unrated branch can never register a loading)
    :scan,
    # %{position => %{load_mw, gen_mw, bus_count, mw_at_risk}} for branches that
    # are graph bridges; the figures describe the side WITHOUT the slack bus
    :bridges,
    # positions currently outaged, most recent first
    :outages,
    :max_outages
  ]

  @type branch_key :: {:line, term()} | {:transformer, term()}

  # A cached solve carries the same soundness guard as the one-shot DC path:
  # unpivoted LDL^T factors an indefinite B' without complaint, so the residual
  # is what says whether the answer means anything.
  @residual_tolerance 1.0e-6

  # |1 - PTDF[k,k]| below this is an island split rather than a very sensitive
  # outage. A true bridge gives exactly 0 in exact arithmetic; at 50k buses
  # round-off lands it near 1e-12, and the smallest genuine denominators seen
  # on real networks are orders of magnitude above this.
  @singular_threshold 1.0e-7

  # Refuse-rather-than-degrade horizon on cumulative trips. See the moduledoc:
  # the math stays exact well past this, the conditioning of the dense
  # (I - Psi) solve does not, and neither survives a redispatch.
  @default_max_outages 16

  @doc """
  Build LODF state from a snapshot and its DC base solution.

  Factors B' once. The snapshot must be the same one the base solution was
  produced from, and must be a single connected island.

  Options:

    * `:base_mva` — per-unit power base (default 100.0)
    * `:max_outages` — cumulative-trip validity horizon (default
      #{@default_max_outages})
    * `:flow_tolerance_mw` — how far a branch flow recomputed from the base
      solution's angles may sit from the solution's own reported flow before
      `init` refuses (default 1.0e-6 MW, i.e. floating-point noise)

  Returns `{:ok, state}` or one of:

    * `{:error, {:disconnected, count}}` — snapshot is not one island
    * `{:error, {:flow_convention_mismatch, key, expected_mw, got_mw}}` — this
      module's B' disagrees with the flows in the base solution
    * `{:error, {:residual_too_large, r}}` — B' factored but does not solve
    * `{:error, :factorization_failed}` / `{:error, binary}` — from the NIF
    * `{:error, {:nif_unavailable, message}}`
  """
  @spec init(map(), struct(), keyword()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def init(snapshot, base_solution, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)
    max_outages = Keyword.get(opts, :max_outages, @default_max_outages)
    flow_tol = Keyword.get(opts, :flow_tolerance_mw, 1.0e-6)

    buses = snapshot.buses
    lines = Map.get(snapshot, :lines, [])
    transformers = Map.get(snapshot, :transformers, [])
    generators = Map.get(snapshot, :generators, [])
    loads = Map.get(snapshot, :loads, [])

    n = length(buses)
    bus_index = buses |> Enum.with_index() |> Map.new(fn {b, i} -> {b.id, i} end)

    cond do
      n < 2 ->
        {:error, {:too_small, n}}

      map_size(bus_index) != n ->
        {:error, {:duplicate_bus_ids, n, map_size(bus_index)}}

      true ->
        slack_idx = find_slack_index(buses, generators, bus_index)
        branch_list = build_branches(lines, transformers, bus_index, slack_idx)

        {bridges, components} =
          find_bridges(n, branch_list, loads, generators, bus_index, slack_idx)

        with :ok <- check_connected(components),
             {:ok, base_flows} <- base_flow_vector(branch_list, base_solution, base_mva, flow_tol),
             {:ok, handle} <- factor_b_prime(branch_list, n) do
          state = %__MODULE__{
            n: n,
            size: n - 1,
            slack_idx: slack_idx,
            bus_index: bus_index,
            base_mva: base_mva,
            handle: handle,
            branches: List.to_tuple(branch_list),
            pos_by_key: Map.new(Enum.with_index(branch_list), fn {b, i} -> {b.key, i} end),
            base_flow_mw: List.to_tuple(base_flows),
            scan: build_scan(branch_list, base_flows),
            bridges: bridges,
            outages: [],
            max_outages: max_outages
          }

          case probe_solve(state) do
            :ok -> {:ok, state}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  @doc """
  Trip one branch, accumulating it into the outage set.

  Returns:

    * `{:ok, state, line_flows}` — `line_flows` has the same shape as
      `Solution.line_flows` (`p_flow_mw`, `rating_mva`, `loading_pct`,
      `overloaded`, ...), with the outaged branches removed from the map, which
      is what a re-solve of the reduced network would produce.
    * `{:island_split, state, info}` — the outage disconnects the network. The
      branch is NOT added to the outage set (there is no flow solution to
      offer); `info` carries `:branch`, `:reason`, and for a precomputed bridge
      the `:islanded_load_mw` / `:islanded_gen_mw` / `:islanded_bus_count` of
      the separated side and the resulting `:mw_at_risk` shortfall.
    * `{:error, state, reason}` — unknown branch key, validity horizon
      exceeded, or a failed solve. Never a silently degraded answer.
  """
  @spec trip_line(%__MODULE__{}, branch_key()) ::
          {:ok, %__MODULE__{}, map()}
          | {:island_split, %__MODULE__{}, map()}
          | {:error, %__MODULE__{}, term()}
  def trip_line(%__MODULE__{} = state, branch_key), do: trip_lines(state, [branch_key])

  @doc """
  Trip several branches at once, accumulating them into the outage set.

  Same return shapes as `trip_line/2`. The outage set is solved as a single
  rank-k update, not as a sequence of single outages, so the result is the
  exact DC answer for the simultaneous outage (see the moduledoc).
  """
  @spec trip_lines(%__MODULE__{}, [branch_key()]) ::
          {:ok, %__MODULE__{}, map()}
          | {:island_split, %__MODULE__{}, map()}
          | {:error, %__MODULE__{}, term()}
  def trip_lines(%__MODULE__{} = state, branch_keys) do
    keys = Enum.reject(branch_keys, &tripped?(state, &1))

    case Enum.split_with(keys, &Map.has_key?(state.pos_by_key, &1)) do
      {_known, [unknown | _]} ->
        {:error, state, {:unknown_branch, unknown}}

      {known, []} ->
        new_positions = Enum.map(known, &Map.fetch!(state.pos_by_key, &1))
        outages = Enum.uniq(new_positions ++ state.outages)

        if length(outages) > state.max_outages do
          {:error, state, {:validity_horizon_exceeded, length(outages), state.max_outages}}
        else
          apply_outage_set(state, outages)
        end
    end
  end

  @doc """
  Flows under a hypothetical outage set, leaving the state untouched.

  The outage set is exactly the branches given — it does not include whatever
  `trip_line/2` has already accumulated. Same return shapes as `trip_line/2`,
  minus the state (`{:ok, line_flows}` / `{:island_split, info}` /
  `{:error, reason}`).
  """
  @spec outage_flows(%__MODULE__{}, [branch_key()]) ::
          {:ok, map()} | {:island_split, map()} | {:error, term()}
  def outage_flows(%__MODULE__{} = state, branch_keys) do
    case trip_lines(%{state | outages: []}, branch_keys) do
      {:ok, _state, flows} -> {:ok, flows}
      {:island_split, _state, info} -> {:island_split, info}
      {:error, _state, reason} -> {:error, reason}
    end
  end

  @doc """
  Current flows: the base case, or the post-outage flows if anything is tripped.
  """
  @spec flows(%__MODULE__{}) :: map()
  def flows(%__MODULE__{outages: []} = state) do
    build_flow_map(state, fn _pos -> 0.0 end, MapSet.new())
  end

  def flows(%__MODULE__{} = state) do
    case solve_outage_set(state, state.outages) do
      {:ok, delta} -> build_flow_map(state, delta, MapSet.new(state.outages))
      _ -> build_flow_map(state, fn _pos -> 0.0 end, MapSet.new(state.outages))
    end
  end

  @doc "Clear the outage set, returning to the base case."
  @spec reset(%__MODULE__{}) :: %__MODULE__{}
  def reset(%__MODULE__{} = state), do: %{state | outages: []}

  @doc """
  Has the cumulative outage set reached the point where a fresh factorization
  (a real DC re-solve on the reduced topology) should take over?

  This answers the arithmetic question only. It cannot see a redispatch or a
  load shed, and those invalidate LODF immediately regardless of trip count.
  """
  @spec needs_refactorize?(%__MODULE__{}) :: boolean()
  def needs_refactorize?(%__MODULE__{} = state),
    do: length(state.outages) >= state.max_outages

  @doc "Branch keys in this state's B', in position order."
  @spec branch_keys(%__MODULE__{}) :: [branch_key()]
  def branch_keys(%__MODULE__{branches: branches}),
    do: branches |> Tuple.to_list() |> Enum.map(& &1.key)

  @doc "Currently tripped branch keys."
  @spec tripped_keys(%__MODULE__{}) :: [branch_key()]
  def tripped_keys(%__MODULE__{} = state),
    do: Enum.map(state.outages, fn pos -> elem(state.branches, pos).key end)

  @doc "Is this branch in the outage set?"
  @spec tripped?(%__MODULE__{}, branch_key()) :: boolean()
  def tripped?(%__MODULE__{} = state, branch_key) do
    case Map.fetch(state.pos_by_key, branch_key) do
      {:ok, pos} -> pos in state.outages
      :error -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Screening interface
  #
  # `PowerModel.Analysis.ContingencyScreening` runs tens of thousands of
  # contingencies, where materializing a 60k-entry flow map per outage is not
  # an option. It works instead against the raw sensitivity column and the
  # `scan` list, so these three functions are the seam between the linear
  # algebra (here) and the metric fold (there).
  # ---------------------------------------------------------------------------

  @doc """
  The `{pos, from_red, to_red, b, base_flow_mw, rate_a, base_overload_mw}` scan
  list — rated branches only, in position order.

  `base_overload_mw` is `max(|f| - rate_a, 0)` on the base case, so it is
  positive exactly for a branch that was ALREADY overloaded before any outage.
  """
  @spec scan_list(%__MODULE__{}) :: [tuple()]
  def scan_list(%__MODULE__{scan: scan}), do: scan

  @doc "Branch record at a position: `:key`, `:from_bus_id`, `:to_bus_id`, `:b`, ..."
  @spec branch_at(%__MODULE__{}, non_neg_integer()) :: map()
  def branch_at(%__MODULE__{branches: branches}, pos), do: elem(branches, pos)

  @doc "Base-case flow, in MW, of the branch at a position."
  @spec base_flow_at(%__MODULE__{}, non_neg_integer()) :: float()
  def base_flow_at(%__MODULE__{base_flow_mw: flows}, pos), do: elem(flows, pos)

  @doc "Number of branches in B'."
  @spec branch_count(%__MODULE__{}) :: non_neg_integer()
  def branch_count(%__MODULE__{branches: branches}), do: tuple_size(branches)

  @doc """
  Bridge map: `%{position => %{load_mw:, gen_mw:, bus_count:, mw_at_risk:}}`.

  A branch listed here disconnects the network when it opens. The figures
  describe the side that does NOT keep the slack bus — the side that has to
  balance on its own — and `mw_at_risk` is `|load - generation|` there: load to
  shed if it is short, generation to curtail if it is long.

  Computed once on the intact graph, so after other branches have tripped this
  is a subset of the true bridge set — sound, not complete, which is why the
  singular-matrix test stays in place.
  """
  @spec bridges(%__MODULE__{}) :: %{non_neg_integer() => map()}
  def bridges(%__MODULE__{bridges: bridges}), do: bridges

  @doc """
  Sensitivity columns for a batch of branch positions, in ONE batched solve.

  Returns `{:ok, [{position, x_tuple, denominator}]}` in the order given, where
  `x_tuple` is `B'^-1 (e_from - e_to)` as a tuple (O(1) indexing by reduced bus
  index) and `denominator` is `1 - PTDF[k,k]`. A position whose denominator is
  within `#{@singular_threshold}` of zero is an island split and is returned
  with `denominator` as given — the caller decides.

  Positions that are graph bridges should be filtered out beforehand; solving
  for them is wasted work.
  """
  @spec sensitivity_batch(%__MODULE__{}, [non_neg_integer()]) ::
          {:ok, [{non_neg_integer(), tuple(), float()}]} | {:error, term()}
  def sensitivity_batch(_state, []), do: {:ok, []}

  def sensitivity_batch(%__MODULE__{} = state, positions) do
    rhs_list =
      Enum.map(positions, fn pos ->
        b = elem(state.branches, pos)
        unit_pair_rhs(state.size, b.from_red, b.to_red)
      end)

    case cached_solve_multi(state.handle, rhs_list) do
      {:ok, xs, residual} when residual <= @residual_tolerance ->
        {:ok,
         positions
         |> Enum.zip(xs)
         |> Enum.map(fn {pos, x} ->
           xt = List.to_tuple(x)
           b = elem(state.branches, pos)
           {pos, xt, 1.0 - b.b * (at(xt, b.from_red) - at(xt, b.to_red))}
         end)}

      {:ok, _xs, residual} ->
        {:error, {:residual_too_large, residual}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Is a denominator `1 - PTDF[k,k]` numerically an island split?"
  @spec island_split_denominator?(float()) :: boolean()
  def island_split_denominator?(denom), do: abs(denom) < @singular_threshold

  # ---------------------------------------------------------------------------
  # Outage solve
  # ---------------------------------------------------------------------------

  defp apply_outage_set(state, outages) do
    # A bridge in the intact graph is still a bridge after other branches open,
    # so this test needs no update as trips accumulate.
    case Enum.find(outages, &Map.has_key?(state.bridges, &1)) do
      nil ->
        case solve_outage_set(state, outages) do
          {:ok, delta} ->
            {:ok, %{state | outages: outages},
             build_flow_map(%{state | outages: outages}, delta, MapSet.new(outages))}

          {:island_split, reason} ->
            {:island_split, state,
             %{
               branch: elem(state.branches, hd(outages)).key,
               reason: reason,
               islanded_load_mw: nil,
               islanded_gen_mw: nil,
               islanded_bus_count: nil,
               mw_at_risk: nil
             }}

          {:error, reason} ->
            {:error, state, reason}
        end

      bridge_pos ->
        info = Map.fetch!(state.bridges, bridge_pos)

        {:island_split, state,
         %{
           branch: elem(state.branches, bridge_pos).key,
           reason: :bridge,
           islanded_load_mw: info.load_mw,
           islanded_gen_mw: info.gen_mw,
           islanded_bus_count: info.bus_count,
           mw_at_risk: info.mw_at_risk
         }}
    end
  end

  @doc """
  Solve the multi-outage system for a set of branch positions.

  Returns `{:ok, [{x, weight}]}`: one sensitivity column per outaged branch,
  paired with the weight the rank-`|K|` update gives it. The flow change on any
  branch `l` is then

      delta_f_l = sum_j b_l * (x_j[from_l] - x_j[to_l]) * weight_j

  which is what a caller doing its own bulk scan (N-2 screening) needs, rather
  than a per-branch closure. `{:island_split, reason}` when the outage set
  disconnects the network.

  Pass `:columns` — `%{position => x}` from an earlier `sensitivity_batch/2` —
  to reuse solves across outage sets that share branches. Sensitivity columns
  depend only on the branch, never on what else is out, so in an N-2 sweep each
  seed's column is solved once and reused across every pair it appears in.
  """
  @spec outage_weights(%__MODULE__{}, [non_neg_integer()], keyword()) ::
          {:ok, [{tuple(), float()}]} | {:island_split, atom()} | {:error, term()}
  def outage_weights(state, positions, opts \\ [])

  def outage_weights(_state, [], _opts), do: {:ok, []}

  def outage_weights(%__MODULE__{} = state, positions, opts) do
    cached = Keyword.get(opts, :columns, %{})

    with {:ok, xs} <- columns_for(state, positions, cached) do
      # Psi[i][j]: PTDF of outaged branch i's flow w.r.t. the endpoint injection
      # pair of outaged branch j. M = I - Psi.
      m =
        positions
        |> Enum.with_index()
        |> Enum.map(fn {pos_i, i} ->
          bi = elem(state.branches, pos_i)

          xs
          |> Enum.with_index()
          |> Enum.map(fn {xj, j} ->
            psi = bi.b * (at(xj, bi.from_red) - at(xj, bi.to_red))
            if i == j, do: 1.0 - psi, else: -psi
          end)
        end)

      f_k = Enum.map(positions, fn pos -> elem(state.base_flow_mw, pos) end)

      case dense_solve(m, f_k) do
        {:ok, y} ->
          {:ok, Enum.zip(xs, y)}

        {:error, :singular} ->
          {:island_split,
           if(length(positions) == 1, do: :zero_denominator, else: :singular_outage_set)}
      end
    end
  end

  defp columns_for(state, positions, cached) do
    missing = Enum.reject(positions, &Map.has_key?(cached, &1))

    with {:ok, solved} <- sensitivity_batch(state, missing) do
      all = Enum.reduce(solved, cached, fn {pos, x, _d}, acc -> Map.put(acc, pos, x) end)
      {:ok, Enum.map(positions, &Map.fetch!(all, &1))}
    end
  end

  # Returns `{:ok, delta_fn}` where `delta_fn.(position)` is the MW change on
  # that branch, `{:island_split, reason}`, or `{:error, reason}`.
  defp solve_outage_set(_state, []), do: {:ok, fn _pos -> 0.0 end}

  defp solve_outage_set(state, outages) do
    case outage_weights(state, outages) do
      {:ok, pairs} ->
        {:ok, delta_function(state, pairs)}

      {:island_split, reason} ->
        {:island_split, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `delta.(position)` — the MW flow change on a branch under the outage set.
  # Closes over the sensitivity columns and their solved weights, so a caller
  # that wants only a handful of branches pays only for those.
  defp delta_function(state, pairs) do
    fn pos ->
      b = elem(state.branches, pos)

      Enum.reduce(pairs, 0.0, fn {x, yj}, acc ->
        acc + b.b * (at(x, b.from_red) - at(x, b.to_red)) * yj
      end)
    end
  end

  # Slack-bus angle is fixed at zero, so a slack endpoint contributes nothing.
  defp at(_x, nil), do: 0.0
  defp at(x, idx), do: elem(x, idx)

  # ---------------------------------------------------------------------------
  # Small dense solve for (I - Psi) y = f_K
  #
  # |K| is bounded by :max_outages (16 by default), so a straightforward
  # Gaussian elimination with partial pivoting is both fast enough and the
  # right factorization: I - Psi is generally NOT symmetric.
  # ---------------------------------------------------------------------------

  # Public so the pivoting path is directly testable: it only fires when a
  # later row has the larger pivot, which a small well-conditioned fixture
  # never produces, and it went out broken once for exactly that reason.
  @doc false
  def dense_solve([[a]], [b]) do
    if abs(a) < @singular_threshold, do: {:error, :singular}, else: {:ok, [b / a]}
  end

  def dense_solve(m, b) do
    k = length(m)

    aug =
      m
      |> Enum.zip(b)
      |> Enum.map(fn {row, rhs} -> :array.from_list(row ++ [rhs]) end)
      |> :array.from_list()

    scale = m |> Enum.flat_map(& &1) |> Enum.reduce(0.0, fn v, acc -> max(acc, abs(v)) end)
    pivot_floor = max(@singular_threshold, scale * 1.0e-12)

    try do
      aug = eliminate(aug, k, pivot_floor)
      {:ok, back_substitute(aug, k, pivot_floor)}
    catch
      :singular -> {:error, :singular}
    end
  end

  defp eliminate(aug, k, pivot_floor) do
    Enum.reduce(0..(k - 2), aug, fn col, aug ->
      {max_val, max_row} =
        Enum.reduce(col..(k - 1), {0.0, col}, fn r, {mv, mr} ->
          v = abs(aug_get(aug, r, col))
          if v > mv, do: {v, r}, else: {mv, mr}
        end)

      if max_val < pivot_floor, do: throw(:singular)

      aug =
        if max_row != col do
          rc = :array.get(col, aug)
          rm = :array.get(max_row, aug)
          swapped = :array.set(col, rm, aug)
          :array.set(max_row, rc, swapped)
        else
          aug
        end

      pivot_row = :array.get(col, aug)
      pivot = :array.get(col, pivot_row)

      Enum.reduce((col + 1)..(k - 1), aug, fn r, aug ->
        row = :array.get(r, aug)
        factor = :array.get(col, row) / pivot

        if factor == 0.0 do
          aug
        else
          new_row =
            Enum.reduce(col..k, row, fn c, acc ->
              :array.set(c, :array.get(c, acc) - factor * :array.get(c, pivot_row), acc)
            end)

          :array.set(r, new_row, aug)
        end
      end)
    end)
  end

  defp back_substitute(aug, k, pivot_floor) do
    Enum.reduce((k - 1)..0//-1, :array.new(k, default: 0.0), fn r, x ->
      row = :array.get(r, aug)

      sum =
        Enum.reduce((r + 1)..(k - 1)//1, 0.0, fn c, acc ->
          acc + :array.get(c, row) * :array.get(c, x)
        end)

      diag = :array.get(r, row)
      if abs(diag) < pivot_floor, do: throw(:singular)

      :array.set(r, (:array.get(k, row) - sum) / diag, x)
    end)
    |> :array.to_list()
  end

  defp aug_get(aug, r, c), do: :array.get(c, :array.get(r, aug))

  # ---------------------------------------------------------------------------
  # Assembly — every convention here must match DCPowerFlow
  # ---------------------------------------------------------------------------

  defp build_branches(lines, transformers, bus_index, slack_idx) do
    line_branches =
      Enum.map(lines, fn line ->
        branch_record(
          {:line, line.id},
          line,
          1.0 / YBus.effective_reactance(line.x_pu),
          bus_index,
          slack_idx
        )
      end)

    xfmr_branches =
      Enum.map(transformers, fn xfmr ->
        t = effective_tap_ratio(Map.get(xfmr, :tap_ratio))

        branch_record(
          {:transformer, xfmr.id},
          xfmr,
          1.0 / (t * YBus.effective_reactance(xfmr.x_pu)),
          bus_index,
          slack_idx
        )
      end)

    line_branches ++ xfmr_branches
  end

  defp branch_record(key, branch, b_pu, bus_index, slack_idx) do
    i = Map.fetch!(bus_index, branch.from_bus_id)
    j = Map.fetch!(bus_index, branch.to_bus_id)
    {rate_a, rate_b, rate_c} = Ratings.branch_ratings(branch)

    %{
      key: key,
      from_bus_id: branch.from_bus_id,
      to_bus_id: branch.to_bus_id,
      from_idx: i,
      to_idx: j,
      from_red: reduced_index(i, slack_idx),
      to_red: reduced_index(j, slack_idx),
      # Susceptance in per unit; flow_pu = b * (theta_from - theta_to).
      b: b_pu,
      rate_a: rate_a,
      rate_b: rate_b,
      rate_c: rate_c
    }
  end

  defp reduced_index(i, slack_idx) when i == slack_idx, do: nil
  defp reduced_index(i, slack_idx) when i < slack_idx, do: i
  defp reduced_index(i, _slack_idx), do: i - 1

  defp effective_tap_ratio(t) when is_number(t) and t > 0.0, do: t
  defp effective_tap_ratio(_), do: 1.0

  defp find_slack_index(buses, generators, bus_index) do
    case Enum.find(buses, &(&1.bus_type == 3)) do
      nil ->
        gen_by_bus = Enum.group_by(generators, & &1.bus_id)

        {max_bus_id, _} =
          Enum.max_by(
            gen_by_bus,
            fn {_id, gens} -> Enum.sum(Enum.map(gens, & &1.p_max_mw)) end,
            fn -> {hd(buses).id, []} end
          )

        Map.fetch!(bus_index, max_bus_id)

      slack ->
        Map.fetch!(bus_index, slack.id)
    end
  end

  # Identical emission rule to DCPowerFlow.add_branch_triplets/5: four entries
  # per branch, anything touching the slack row or column simply not emitted.
  defp factor_b_prime(branches, n) do
    {rows, cols, vals} =
      Enum.reduce(branches, {[], [], []}, fn br, {rs, cs, vs} ->
        case {br.from_red, br.to_red} do
          {nil, nil} ->
            {rs, cs, vs}

          {nil, j} ->
            {[j | rs], [j | cs], [br.b | vs]}

          {i, nil} ->
            {[i | rs], [i | cs], [br.b | vs]}

          {i, j} ->
            {[i, j, i, j | rs], [i, j, j, i | cs], [br.b, br.b, -br.b, -br.b | vs]}
        end
      end)

    case Sparse.sparse_factor(rows, cols, vals, n - 1) do
      {:ok, handle} -> {:ok, handle}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:nif_unavailable, Exception.message(error)}}
  end

  defp cached_solve_multi(handle, rhs_list) do
    Sparse.sparse_cached_solve_multi(handle, rhs_list)
  rescue
    error -> {:error, {:nif_unavailable, Exception.message(error)}}
  end

  # One cheap solve whose only job is to prove the factorization actually
  # solves. `sparse_factor` succeeding means nothing on its own: unpivoted
  # LDL^T factors an indefinite B' without complaint.
  defp probe_solve(%__MODULE__{size: size} = state) do
    rhs = unit_pair_rhs(size, 0, min(1, size - 1))

    case cached_solve_multi(state.handle, [rhs]) do
      {:ok, _xs, residual} when residual <= @residual_tolerance ->
        :ok

      {:ok, _xs, residual} ->
        Logger.warning(
          "LODF init: B' factored but solves to relative residual #{residual} " <>
            "(tolerance #{@residual_tolerance}) on a #{size}x#{size} system; refusing"
        )

        {:error, {:residual_too_large, residual}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Base flows, recomputed from the base solution's own angles. Doing it this
  # way rather than lifting `p_flow_mw` straight out of the solution is
  # deliberate: the comparison that follows is what pins this module's
  # susceptance convention to the DC solver's, so a future drift in either
  # (a reactance floor, a tap model) fails loudly at init instead of producing
  # screening results that quietly disagree with the solved flows.
  defp base_flow_vector(branches, base_solution, base_mva, tol_mw) do
    theta =
      base_solution.bus_ids
      |> Enum.zip(base_solution.va_rad)
      |> Map.new()

    flows = base_solution.line_flows

    Enum.reduce_while(branches, {:ok, []}, fn br, {:ok, acc} ->
      ti = Map.get(theta, br.from_bus_id)
      tj = Map.get(theta, br.to_bus_id)

      cond do
        ti == nil or tj == nil ->
          {:halt, {:error, {:bus_missing_from_solution, br.key}}}

        true ->
          computed = br.b * (ti - tj) * base_mva

          case Map.fetch(flows, br.key) do
            {:ok, %{p_flow_mw: reported}} when is_number(reported) ->
              if abs(computed - reported) > tol_mw + 1.0e-9 * abs(reported) do
                {:halt, {:error, {:flow_convention_mismatch, br.key, reported, computed}}}
              else
                {:cont, {:ok, [reported | acc]}}
              end

            _ ->
              {:halt, {:error, {:branch_missing_from_solution, br.key}}}
          end
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  # Rated branches only: an unrated branch reports 0% loading by the existing
  # solver convention (`Ratings.loading_pct/2`), so it can neither overload nor
  # set a maximum, and every screening pass would pay for it on every outage.
  defp build_scan(branches, base_flows) do
    branches
    |> Enum.zip(base_flows)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{br, f0}, pos} ->
      case br.rate_a do
        rate when is_number(rate) and rate > 0.0 ->
          [{pos, br.from_red, br.to_red, br.b, f0, rate, max(abs(f0) - rate, 0.0)}]

        _ ->
          []
      end
    end)
  end

  defp unit_pair_rhs(size, nil, nil), do: List.duplicate(0.0, size)
  defp unit_pair_rhs(size, i, i), do: List.duplicate(0.0, size)
  defp unit_pair_rhs(size, i, nil), do: spike(size, i, 1.0)
  defp unit_pair_rhs(size, nil, j), do: spike(size, j, -1.0)

  defp unit_pair_rhs(size, i, j) when i < j do
    List.duplicate(0.0, i) ++
      [1.0] ++
      List.duplicate(0.0, j - i - 1) ++ [-1.0] ++ List.duplicate(0.0, size - j - 1)
  end

  defp unit_pair_rhs(size, i, j) do
    List.duplicate(0.0, j) ++
      [-1.0] ++
      List.duplicate(0.0, i - j - 1) ++ [1.0] ++ List.duplicate(0.0, size - i - 1)
  end

  defp spike(size, i, v),
    do: List.duplicate(0.0, i) ++ [v] ++ List.duplicate(0.0, size - i - 1)

  defp injected_mw(gen), do: (gen.p_max_mw || 0.0) * (Map.get(gen, :capacity_factor) || 1.0)

  # ---------------------------------------------------------------------------
  # Flow map reconstruction (the `Solution.line_flows` shape)
  # ---------------------------------------------------------------------------

  defp build_flow_map(state, delta, outage_set) do
    state.branches
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reject(fn {_br, pos} -> MapSet.member?(outage_set, pos) end)
    |> Map.new(fn {br, pos} ->
      flow_mw = elem(state.base_flow_mw, pos) + delta.(pos)

      {br.key,
       %{
         from_bus_id: br.from_bus_id,
         to_bus_id: br.to_bus_id,
         p_flow_mw: flow_mw,
         rating_mva: br.rate_a,
         rating_b_mva: br.rate_b,
         rating_c_mva: br.rate_c,
         loading_pct: Ratings.loading_pct(flow_mw, br.rate_a),
         emergency_loading_pct: Ratings.loading_pct(flow_mw, br.rate_b),
         trip_loading_pct: Ratings.loading_pct(flow_mw, br.rate_c),
         overloaded: is_number(br.rate_a) and abs(flow_mw) > br.rate_a
       }}
    end)
  end

  # ---------------------------------------------------------------------------
  # Bridges
  #
  # A branch whose removal disconnects the graph has no LODF: the flow has
  # nowhere to redistribute to, and `1 - PTDF[k,k]` is zero. Finding them all
  # up front (Tarjan low-link, one DFS, O(V+E)) means the screening sweep never
  # pays for a solve it will have to throw away, and it turns "is this an
  # island split?" from a floating-point judgement into a graph fact.
  #
  # The same DFS carries subtree sums of load and generation, so each bridge
  # also knows how much of the system separates — the ranking metric for a
  # split, which a flow-based one cannot express.
  #
  # Parallel circuits are handled by skipping the specific EDGE the search
  # entered a bus by, never the parent bus: two circuits between the same pair
  # of substations are not a bridge, and a parent-vertex test would wrongly
  # call them one.
  #
  # Written with an explicit stack rather than recursion: a transmission
  # network has long radial chains, and DFS depth tracks them.
  # ---------------------------------------------------------------------------

  defp find_bridges(n, branches, loads, generators, bus_index, slack_idx) do
    ctx = %{
      adj: build_adjacency(branches),
      load: by_bus_index(loads, bus_index, &(&1.p_mw || 0.0)),
      gen: by_bus_index(generators, bus_index, &injected_mw/1)
    }

    acc =
      Enum.reduce(
        0..(n - 1),
        %{disc: %{}, low: %{}, counter: 0, raw: %{}, components: %{}},
        fn root, acc ->
          if Map.has_key?(acc.disc, root), do: acc, else: dfs_component(root, ctx, acc)
        end
      )

    {resolve_bridges(acc, slack_idx), map_size(acc.components)}
  end

  defp by_bus_index(rows, bus_index, value_fun) do
    Enum.reduce(rows, %{}, fn row, acc ->
      case Map.fetch(bus_index, row.bus_id) do
        {:ok, idx} -> Map.update(acc, idx, value_fun.(row), &(&1 + value_fun.(row)))
        :error -> acc
      end
    end)
  end

  # Which side of a bridge is "the island"?
  #
  # The side WITHOUT the slack bus. That is not a presentation choice: the DC
  # solve balances the system at the slack, so the side that keeps the slack
  # keeps its ability to absorb an imbalance, and the side that loses it has to
  # balance internally or shed. Reporting the DFS subtree instead would name a
  # different side depending on where the search happened to start.
  #
  # The subtree of `v` occupies the contiguous discovery range
  # `[disc[v], disc[v] + size)` — that is what a preorder DFS numbering buys —
  # so containment is a range test rather than a second traversal.
  defp resolve_bridges(acc, slack_idx) do
    slack_disc = Map.get(acc.disc, slack_idx)

    Map.new(acc.raw, fn {edge, r} ->
      {c_load, c_gen, c_size} = Map.fetch!(acc.components, r.root)

      slack_inside? =
        slack_disc != nil and slack_disc >= r.disc and slack_disc < r.disc + r.size

      {load, gen, size} =
        if slack_inside?,
          do: {c_load - r.load, c_gen - r.gen, c_size - r.size},
          else: {r.load, r.gen, r.size}

      # Whichever way the imbalance runs, something has to give: load shed if
      # the island is short, generation curtailed if it is long. Both are
      # megawatts the split puts at risk.
      {edge, %{load_mw: load, gen_mw: gen, bus_count: size, mw_at_risk: abs(load - gen)}}
    end)
  end

  defp build_adjacency(branches) do
    branches
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {br, pos}, acc ->
      if br.from_idx == br.to_idx do
        # A self-loop carries no flow and can never disconnect anything.
        acc
      else
        acc
        |> Map.update(br.from_idx, [{br.to_idx, pos}], &[{br.to_idx, pos} | &1])
        |> Map.update(br.to_idx, [{br.from_idx, pos}], &[{br.from_idx, pos} | &1])
      end
    end)
  end

  # Iterative DFS. Each stack frame is
  # {vertex, entering_edge, remaining_neighbours, subtree_load, subtree_gen,
  #  subtree_buses}.
  defp dfs_component(root, ctx, acc) do
    acc = %{
      acc
      | disc: Map.put(acc.disc, root, acc.counter),
        low: Map.put(acc.low, root, acc.counter),
        counter: acc.counter + 1
    }

    dfs_loop([new_frame(root, nil, ctx)], ctx, root, acc)
  end

  defp new_frame(v, entering_edge, ctx) do
    {v, entering_edge, Map.get(ctx.adj, v, []), Map.get(ctx.load, v, 0.0),
     Map.get(ctx.gen, v, 0.0), 1}
  end

  defp dfs_loop([{_v, _edge, [], sl, sg, sb}], _ctx, root, acc) do
    # The root frame is finished, so the whole component is: record its totals,
    # which `resolve_bridges/2` needs to describe the far side of each bridge.
    %{acc | components: Map.put(acc.components, root, {sl, sg, sb})}
  end

  defp dfs_loop(
         [{v, edge, [], sl, sg, sb}, {pv, pe, pn, psl, psg, psb} | outer],
         ctx,
         root,
         acc
       ) do
    # v is finished: fold it into its parent and decide whether the edge that
    # reached it is a bridge.
    low_v = Map.fetch!(acc.low, v)
    acc = %{acc | low: Map.update!(acc.low, pv, &min(&1, low_v))}

    acc =
      if low_v > Map.fetch!(acc.disc, pv) do
        record = %{load: sl, gen: sg, size: sb, disc: Map.fetch!(acc.disc, v), root: root}
        %{acc | raw: Map.put(acc.raw, edge, record)}
      else
        acc
      end

    dfs_loop([{pv, pe, pn, psl + sl, psg + sg, psb + sb} | outer], ctx, root, acc)
  end

  defp dfs_loop([{v, edge, [{w, e} | rest_n], sl, sg, sb} | rest], ctx, root, acc) do
    frame = {v, edge, rest_n, sl, sg, sb}

    cond do
      e == edge ->
        # The edge we came in by — skipped once, by edge identity, so a
        # parallel circuit between the same buses is still explored.
        dfs_loop([frame | rest], ctx, root, acc)

      Map.has_key?(acc.disc, w) ->
        acc = %{acc | low: Map.update!(acc.low, v, &min(&1, Map.fetch!(acc.disc, w)))}
        dfs_loop([frame | rest], ctx, root, acc)

      true ->
        acc = %{
          acc
          | disc: Map.put(acc.disc, w, acc.counter),
            low: Map.put(acc.low, w, acc.counter),
            counter: acc.counter + 1
        }

        dfs_loop([new_frame(w, e, ctx), frame | rest], ctx, root, acc)
    end
  end

  # The bridge DFS visits every vertex, so the component count falls out of the
  # same walk. A B' with more than one component is singular, and no
  # factorization of it means anything — refuse before paying for one.
  defp check_connected(1), do: :ok
  defp check_connected(components), do: {:error, {:disconnected, components}}
end
