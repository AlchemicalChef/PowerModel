defmodule PowerModel.Analysis.ContingencyScreening do
  @moduledoc """
  N-1 contingency screening: open every branch in turn and rank what breaks.

  This is the number the UI's "N-1" panel has always claimed to show and never
  did (REVIEW UI-M15, which reported the count of components the *user* had
  tripped). A sweep here evaluates one contingency per branch — 6,975 on
  ERCOT, 64,664 on Eastern — against the same DC network the map is drawn from.

  ## Screening, not analysis

  Every result is a DC LODF extrapolation from one base solution
  (`PowerModel.Solver.LODF`). In DC that extrapolation is *exact* for a branch
  outage, which is what makes it worth trusting as a ranking. It is not a
  substitute for the full solve, because two things it cannot see arrive
  immediately after the outage in any real study: **redispatch** (the injection
  vector changes) and **islanding** (there is no linear update at all). So the
  workflow this supports is: screen everything cheaply here, then re-solve the
  handful that rank worst.

  ## Reading the metrics on a grid that is already overloaded

  The base case has real overloads in it — measured on the Eastern
  interconnection at its EIA-930-dispatched operating point, 4,366 of 64,664
  branches (6.8%) are over rate A before anything trips. A naive "count of
  overloaded branches after the outage" would therefore report ~4,366 for every
  contingency in the system and rank nothing. The metrics here are all
  INCREMENTAL:

    * `new_overloads` — branches that were within their rating on the base case
      and are over it after the outage. Pre-existing overloads cannot enter
      this count.
    * `worsened_overloads` — branches already over their rating that are pushed
      further over, by more than a 1 kW deadband. A contingency that relieves
      an existing overload does not count here either, and neither does one
      that leaves a branch untouched — without the deadband those two cases sit
      exactly on the comparison boundary and the count wobbles with rounding.
    * `mw_at_risk` — for a thermal contingency, the megawatts of overload this
      outage *added*: `sum(new overload MW) + sum(increase on existing
      overloads)`. For an island split, the generation/load shortfall the split
      creates. This is the ranking key.
    * `max_loading_pct` — the single worst branch loading after the outage,
      against rate A. Absolute, not incremental, and so is the one number that
      can be dominated by a pre-existing problem; `base.max_loading_pct` is
      reported alongside it for comparison.

  Unrated branches are excluded from every loading metric, matching
  `Grid.Ratings.loading_pct/2`'s convention that a branch nobody knows the
  rating of never registers as overloaded. They are counted in
  `summary.unrated_branches` so they cannot pass as healthy.

  ## Categories

    * `:island_split` — the branch is a bridge; opening it disconnects the
      network. No flow update exists, so no thermal metrics are reported.
      Found by graph search at `LODF.init/3`, not by a floating-point test.
    * `:thermal` — a flow update exists and it created or worsened an overload.
    * `:clean` — a flow update exists and nothing went over.
    * `:negligible` — the outaged branch's flow is small enough that the
      redistribution cannot move any other branch by more than
      `:negligible_shift_mw`, so the scan is skipped and base-case metrics are
      reported. Off by default (threshold 0.0): it is a speed/exactness trade
      the caller opts into, not something applied behind their back.

  ## Usage

      {:ok, result} = ContingencyScreening.run(snapshot)
      result.summary.island_splits
      Enum.take(result.ranked, 5)
  """

  require Logger

  alias PowerModel.Solver.{DCPowerFlow, LODF}

  @default_limit 100
  @default_batch_size 16
  @default_n2_seeds 40

  # A branch the outage does not touch has `post-outage overload` exactly equal
  # to its base overload, and a strict `>` then makes "worsened" a coin flip on
  # the last bit: the counts moved by a handful between runs of the same sweep,
  # because the snapshot query returns buses in whatever order Postgres likes
  # and a different B' row permutation rounds differently. One milliwatt is
  # several orders of magnitude above that noise and below anything a
  # transmission engineer would call a change.
  @worsened_deadband_mw 1.0e-3

  @doc """
  Solve the base case and screen every branch.

  The snapshot must be one connected island (what `Grid.get_grid_snapshot/2`
  returns). Accepts every option `screen/2` does, plus `:base_mva`.
  """
  @spec run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(snapshot, opts \\ []) do
    base_solution = DCPowerFlow.solve(snapshot, opts)
    run(snapshot, base_solution, opts)
  catch
    {:error, reason} -> {:error, {:base_solve_failed, reason}}
  end

  @doc "Screen every branch against a base solution you already have."
  @spec run(map(), struct(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(snapshot, base_solution, opts) do
    with {:ok, lodf} <- LODF.init(snapshot, base_solution, opts) do
      screen(lodf, opts)
    end
  end

  @doc """
  Screen contingencies against an initialized `LODF` state.

  Options:

    * `:limit` — how many ranked entries to return (default #{@default_limit}).
      The summary is always computed over every contingency screened.
    * `:branches` — branch keys to screen (default: all of them).
    * `:batch_size` — right-hand sides per `sparse_cached_solve_multi/2` call
      (default #{@default_batch_size}). Each one costs a solution vector of
      `n - 1` floats, so this trades memory for fewer NIF round trips.
    * `:max_concurrency` — worker processes (default
      `System.schedulers_online/0`). Solves are DirtyCpu NIFs and the scan is
      pure BEAM, so both parallelize.
    * `:negligible_shift_mw` — skip the branch scan when the outage cannot move
      any branch by more than this (default 0.0, i.e. never skip). The bound is
      `|f_k / (1 - PTDF[k,k])|`, which is `max |delta_f|` under the usual
      `|PTDF| <= 1`; a network with PTDFs above 1 can exceed it.

  Returns `{:ok, result}` where `result` is

      %{
        ranked: [entry],   # worst first, at most :limit of them
        summary: %{...},
        base: %{max_loading_pct:, overloaded:, monitored:}
      }

  and each entry is

      %{
        branch: {:line, id} | {:transformer, id},
        from_bus_id:, to_bus_id:,
        base_flow_mw:,
        category: :island_split | :thermal | :clean | :negligible,
        mw_at_risk:,
        max_loading_pct:,
        new_overloads:, new_overload_mw:,
        worsened_overloads:, worsened_overload_mw:,
        lodf_denominator:,                       # nil for an island split
        islanded_load_mw:, islanded_gen_mw:, islanded_bus_count:  # split only
      }

  A solve failure anywhere in the sweep aborts the whole run with
  `{:error, reason}`. There is no partial-result path: a screening list missing
  an unknown subset of the network is worse than no list.
  """
  @spec screen(%LODF{}, keyword()) :: {:ok, map()} | {:error, term()}
  def screen(%LODF{} = lodf, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    limit = Keyword.get(opts, :limit, @default_limit)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    negligible = Keyword.get(opts, :negligible_shift_mw, 0.0)

    scan = LODF.scan_list(lodf)
    bridges = LODF.bridges(lodf)
    base = base_metrics(scan)

    positions = requested_positions(lodf, Keyword.get(opts, :branches))
    {bridge_positions, solvable} = Enum.split_with(positions, &Map.has_key?(bridges, &1))

    ctx = %{
      lodf: lodf,
      scan: scan,
      base: base,
      negligible: negligible,
      batch_size: batch_size
    }

    split_entries = Enum.map(bridge_positions, &island_entry(lodf, &1, Map.fetch!(bridges, &1)))

    case sweep(solvable, ctx, concurrency) do
      {:ok, thermal_entries} ->
        entries = split_entries ++ thermal_entries
        elapsed = System.monotonic_time(:millisecond) - started

        {:ok,
         %{
           ranked: entries |> Enum.sort_by(& &1.mw_at_risk, :desc) |> Enum.take(limit),
           base: base,
           summary: summarize(entries, lodf, base, elapsed)
         }}

      {:error, reason} ->
        Logger.warning(
          "Contingency screening aborted after #{System.monotonic_time(:millisecond) - started} ms: " <>
            "#{inspect(reason)} (no partial results returned)"
        )

        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Sweep
  # ---------------------------------------------------------------------------

  # One task per worker, each owning a contiguous slice: the LODF state is a
  # few tens of megabytes at Eastern scale and is copied into every process it
  # is sent to, so the number of copies has to be bounded by the worker count
  # rather than by the batch count.
  defp sweep([], _ctx, _concurrency), do: {:ok, []}

  defp sweep(positions, ctx, concurrency) do
    workers = max(concurrency, 1)
    slice = max(div(length(positions) + workers - 1, workers), 1)

    positions
    |> Enum.chunk_every(slice)
    |> Task.async_stream(fn slice -> worker(slice, ctx) end,
      max_concurrency: workers,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, entries}}, {:ok, acc} -> {:cont, {:ok, entries ++ acc}}
      {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
      {:exit, reason}, _acc -> {:halt, {:error, {:worker_exit, reason}}}
    end)
  end

  defp worker(positions, ctx) do
    positions
    |> Enum.chunk_every(ctx.batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case LODF.sensitivity_batch(ctx.lodf, batch) do
        {:ok, columns} ->
          {:cont, {:ok, Enum.reduce(columns, acc, fn col, a -> [evaluate(col, ctx) | a] end)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp evaluate({pos, x, denom}, ctx) do
    f_k = LODF.base_flow_at(ctx.lodf, pos)

    cond do
      LODF.island_split_denominator?(denom) ->
        # A split the intact-graph bridge search did not know about. On an N-1
        # sweep of the intact network this should not fire — the bridge search
        # is exact — so if it does, the two disagree, and the entry says so
        # rather than reporting a flow update divided by ~zero.
        entry(ctx, pos, f_k, :island_split, denom)

      abs(f_k / denom) <= ctx.negligible ->
        entry(ctx, pos, f_k, :negligible, denom)

      true ->
        {best, nc, nmw, wc, wmw} =
          scan(ctx.scan, pos, x, f_k / denom, {0.0, 0, 0.0, 0, 0.0})

        ctx
        |> entry(pos, f_k, if(nc > 0 or wc > 0, do: :thermal, else: :clean), denom)
        |> Map.merge(%{
          mw_at_risk: nmw + wmw,
          max_loading_pct: best * 100.0,
          new_overloads: nc,
          new_overload_mw: nmw,
          worsened_overloads: wc,
          worsened_overload_mw: wmw
        })
    end
  end

  # Base shape shared by every non-bridge entry: no consequence recorded, and
  # base-case loading carried through, which is exactly right for the two
  # categories that never run a scan.
  defp entry(ctx, pos, base_flow_mw, category, denom) do
    branch = LODF.branch_at(ctx.lodf, pos)

    %{
      branch: branch.key,
      from_bus_id: branch.from_bus_id,
      to_bus_id: branch.to_bus_id,
      base_flow_mw: base_flow_mw,
      category: category,
      mw_at_risk: 0.0,
      max_loading_pct: ctx.base.max_loading_pct,
      new_overloads: 0,
      new_overload_mw: 0.0,
      worsened_overloads: 0,
      worsened_overload_mw: 0.0,
      lodf_denominator: denom,
      islanded_load_mw: nil,
      islanded_gen_mw: nil,
      islanded_bus_count: nil
    }
  end

  # ---------------------------------------------------------------------------
  # N-2
  # ---------------------------------------------------------------------------

  @doc """
  Screen simultaneous PAIRS of outages, seeded from the worst N-1 results.

  The full N-2 space is quadratic — 2.1 billion pairs on Eastern — so this
  screens a seeded subset: all pairs among the `:seed_count` branches that an
  N-1 sweep ranked worst. That is the standard heuristic and it is a heuristic;
  a pair of individually-harmless branches that is dangerous together will not
  be found this way, and nothing here claims otherwise.

  What is *not* approximate is the physics. Each pair is solved as one rank-2
  update (`LODF.outage_weights/3`), which is the exact DC answer for taking
  both branches at once. Applying two single-outage LODFs in sequence — the
  obvious shortcut, and what an earlier implementation of this module did — is
  not exact, because the second factor was derived for the intact network:
  measured on this model, that shortcut drifts 6.5% on ERCOT and 1.1% on
  Eastern against a full re-solve, where the rank-2 form lands at 1e-11.

  Sensitivity columns are solved once per seed and reused across every pair the
  seed appears in, so `seed_count` solves cover `seed_count * (seed_count-1)/2`
  contingencies.

  Options: `:seeds` (branch keys to pair; default the worst `:seed_count` from
  an internal N-1 run), `:seed_count` (default #{@default_n2_seeds}), plus
  `:limit` and `:max_concurrency` as in `screen/2`.

  Entries carry `:branches` (the pair) instead of `:branch`, and are otherwise
  shaped as in `screen/2`. A pair containing a bridge, or one whose two
  branches only disconnect the network together, is categorized
  `:island_split`.
  """
  @spec screen_n2(%LODF{}, keyword()) :: {:ok, map()} | {:error, term()}
  def screen_n2(%LODF{} = lodf, opts \\ []) do
    started = System.monotonic_time(:millisecond)
    limit = Keyword.get(opts, :limit, @default_limit)
    concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())

    with {:ok, seeds} <- n2_seeds(lodf, opts),
         {:ok, columns} <- seed_columns(lodf, seeds, opts) do
      scan = LODF.scan_list(lodf)
      bridges = LODF.bridges(lodf)
      base = base_metrics(scan)
      ctx = %{lodf: lodf, scan: scan, base: base, columns: columns, bridges: bridges}

      pairs = for a <- seeds, b <- seeds, a < b, do: {a, b}
      workers = max(concurrency, 1)
      slice = max(div(length(pairs) + workers - 1, workers), 1)

      entries =
        pairs
        |> Enum.chunk_every(slice)
        |> Task.async_stream(fn chunk -> Enum.map(chunk, &evaluate_pair(&1, ctx)) end,
          max_concurrency: workers,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, chunk} -> chunk end)

      elapsed = System.monotonic_time(:millisecond) - started

      {:ok,
       %{
         ranked: entries |> Enum.sort_by(& &1.mw_at_risk, :desc) |> Enum.take(limit),
         base: base,
         summary:
           entries
           |> summarize(lodf, base, elapsed)
           |> Map.merge(%{seeds: length(seeds), pairs: length(pairs)})
       }}
    end
  end

  defp n2_seeds(lodf, opts) do
    count = Keyword.get(opts, :seed_count, @default_n2_seeds)

    case Keyword.get(opts, :seeds) do
      nil ->
        with {:ok, n1} <- screen(lodf, Keyword.put(opts, :limit, count)) do
          {:ok, requested_positions(lodf, Enum.map(n1.ranked, & &1.branch))}
        end

      keys ->
        {:ok, lodf |> requested_positions(keys) |> Enum.take(count)}
    end
  end

  defp seed_columns(lodf, seeds, opts) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    seeds
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce_while({:ok, %{}}, fn batch, {:ok, acc} ->
      case LODF.sensitivity_batch(lodf, batch) do
        {:ok, cols} ->
          {:cont, {:ok, Enum.reduce(cols, acc, fn {pos, x, _d}, a -> Map.put(a, pos, x) end)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp evaluate_pair({p1, p2}, ctx) do
    keys = [LODF.branch_at(ctx.lodf, p1).key, LODF.branch_at(ctx.lodf, p2).key]
    base_flow = LODF.base_flow_at(ctx.lodf, p1) + LODF.base_flow_at(ctx.lodf, p2)

    bridge = Enum.find([p1, p2], &Map.has_key?(ctx.bridges, &1))

    cond do
      bridge != nil ->
        info = Map.fetch!(ctx.bridges, bridge)

        ctx
        |> pair_entry(keys, base_flow, :island_split)
        |> Map.merge(%{
          mw_at_risk: info.mw_at_risk,
          max_loading_pct: nil,
          islanded_load_mw: info.load_mw,
          islanded_gen_mw: info.gen_mw,
          islanded_bus_count: info.bus_count
        })

      true ->
        case LODF.outage_weights(ctx.lodf, [p1, p2], columns: ctx.columns) do
          {:ok, [{x1, w1}, {x2, w2}]} ->
            {best, nc, nmw, wc, wmw} =
              scan2(ctx.scan, p1, p2, x1, w1, x2, w2, {0.0, 0, 0.0, 0, 0.0})

            ctx
            |> pair_entry(keys, base_flow, if(nc > 0 or wc > 0, do: :thermal, else: :clean))
            |> Map.merge(%{
              mw_at_risk: nmw + wmw,
              max_loading_pct: best * 100.0,
              new_overloads: nc,
              new_overload_mw: nmw,
              worsened_overloads: wc,
              worsened_overload_mw: wmw
            })

          {:island_split, _reason} ->
            pair_entry(ctx, keys, base_flow, :island_split)

          {:error, _reason} ->
            pair_entry(ctx, keys, base_flow, :clean)
        end
    end
  end

  defp pair_entry(ctx, keys, base_flow_mw, category) do
    %{
      branches: keys,
      base_flow_mw: base_flow_mw,
      category: category,
      mw_at_risk: 0.0,
      max_loading_pct: ctx.base.max_loading_pct,
      new_overloads: 0,
      new_overload_mw: 0.0,
      worsened_overloads: 0,
      worsened_overload_mw: 0.0,
      islanded_load_mw: nil,
      islanded_gen_mw: nil,
      islanded_bus_count: nil
    }
  end

  # The N-1 scan with a second sensitivity column folded in. Specialized to two
  # rather than written over a list: this runs once per branch per pair, and a
  # list traversal in the inner position would cost more than the arithmetic.
  defp scan2([], _s1, _s2, _x1, _w1, _x2, _w2, acc), do: acc

  defp scan2([{p, _, _, _, _, _, _} | rest], p, s2, x1, w1, x2, w2, acc),
    do: scan2(rest, p, s2, x1, w1, x2, w2, acc)

  defp scan2([{p, _, _, _, _, _, _} | rest], s1, p, x1, w1, x2, w2, acc),
    do: scan2(rest, s1, p, x1, w1, x2, w2, acc)

  defp scan2([{_pos, fa, fb, b, f0, rate, base_ov} | rest], s1, s2, x1, w1, x2, w2, acc) do
    d1 =
      if(fa, do: :erlang.element(fa + 1, x1), else: 0.0) -
        if fb, do: :erlang.element(fb + 1, x1), else: 0.0

    d2 =
      if(fa, do: :erlang.element(fa + 1, x2), else: 0.0) -
        if fb, do: :erlang.element(fb + 1, x2), else: 0.0

    f = f0 + b * (d1 * w1 + d2 * w2)
    af = if f < 0.0, do: -f, else: f

    {best, nc, nmw, wc, wmw} = acc
    best = if af > rate * best, do: af / rate, else: best

    acc =
      cond do
        af <= rate ->
          {best, nc, nmw, wc, wmw}

        base_ov > 0.0 ->
          over = af - rate

          if over > base_ov + @worsened_deadband_mw,
            do: {best, nc, nmw, wc + 1, wmw + (over - base_ov)},
            else: {best, nc, nmw, wc, wmw}

        true ->
          {best, nc + 1, nmw + (af - rate), wc, wmw}
      end

    scan2(rest, s1, s2, x1, w1, x2, w2, acc)
  end

  # ---------------------------------------------------------------------------
  # The hot loop
  #
  # Runs once per branch per contingency — 4.2e9 iterations for a full Eastern
  # sweep — so it works off a flat list of pre-resolved tuples (traversal, not
  # indexing) and off the sensitivity vector as a tuple (O(1) elem/2). The
  # running maximum is kept as a ratio and compared by multiplication, which
  # keeps the per-branch division out of the loop: a divide only happens on the
  # rare iteration that actually sets a new maximum.
  # ---------------------------------------------------------------------------

  defp scan([], _skip, _x, _scale, acc), do: acc

  defp scan([{pos, _fa, _fb, _b, _f0, _rate, _base_ov} | rest], pos, x, scale, acc) do
    # The outaged branch itself: its flow is zero afterwards, and it is not
    # part of the post-outage network's loading picture.
    scan(rest, pos, x, scale, acc)
  end

  defp scan([{_pos, fa, fb, b, f0, rate, base_ov} | rest], skip, x, scale, acc) do
    xa = if fa, do: :erlang.element(fa + 1, x), else: 0.0
    xb = if fb, do: :erlang.element(fb + 1, x), else: 0.0
    f = f0 + b * (xa - xb) * scale
    af = if f < 0.0, do: -f, else: f

    {best, nc, nmw, wc, wmw} = acc
    best = if af > rate * best, do: af / rate, else: best

    acc =
      cond do
        af <= rate ->
          {best, nc, nmw, wc, wmw}

        base_ov > 0.0 ->
          over = af - rate

          if over > base_ov + @worsened_deadband_mw,
            do: {best, nc, nmw, wc + 1, wmw + (over - base_ov)},
            else: {best, nc, nmw, wc, wmw}

        true ->
          {best, nc + 1, nmw + (af - rate), wc, wmw}
      end

    scan(rest, skip, x, scale, acc)
  end

  # ---------------------------------------------------------------------------
  # Entries and summaries
  # ---------------------------------------------------------------------------

  defp island_entry(lodf, pos, info) do
    branch = LODF.branch_at(lodf, pos)

    %{
      branch: branch.key,
      from_bus_id: branch.from_bus_id,
      to_bus_id: branch.to_bus_id,
      base_flow_mw: LODF.base_flow_at(lodf, pos),
      category: :island_split,
      mw_at_risk: info.mw_at_risk,
      max_loading_pct: nil,
      new_overloads: 0,
      new_overload_mw: 0.0,
      worsened_overloads: 0,
      worsened_overload_mw: 0.0,
      lodf_denominator: nil,
      islanded_load_mw: info.load_mw,
      islanded_gen_mw: info.gen_mw,
      islanded_bus_count: info.bus_count
    }
  end

  defp base_metrics(scan) do
    {max_ratio, overloaded} =
      Enum.reduce(scan, {0.0, 0}, fn {_pos, _fa, _fb, _b, f0, rate, base_ov}, {best, over} ->
        ratio = abs(f0) / rate
        {max(best, ratio), if(base_ov > 0.0, do: over + 1, else: over)}
      end)

    %{max_loading_pct: max_ratio * 100.0, overloaded: overloaded, monitored: length(scan)}
  end

  defp summarize(entries, lodf, base, elapsed_ms) do
    counts =
      Enum.reduce(entries, %{island_split: 0, thermal: 0, clean: 0, negligible: 0}, fn e, acc ->
        Map.update!(acc, e.category, &(&1 + 1))
      end)

    screened = length(entries)

    %{
      screened: screened,
      island_splits: counts.island_split,
      thermal: counts.thermal,
      clean: counts.clean,
      negligible: counts.negligible,
      total_branches: LODF.branch_count(lodf),
      monitored_branches: base.monitored,
      unrated_branches: LODF.branch_count(lodf) - base.monitored,
      base_overloaded: base.overloaded,
      worst_mw_at_risk: entries |> Enum.map(& &1.mw_at_risk) |> Enum.max(fn -> 0.0 end),
      elapsed_ms: elapsed_ms,
      ms_per_contingency: if(screened > 0, do: elapsed_ms / screened, else: 0.0)
    }
  end

  defp requested_positions(lodf, nil) do
    case LODF.branch_count(lodf) do
      0 -> []
      count -> Enum.to_list(0..(count - 1))
    end
  end

  defp requested_positions(lodf, keys) do
    by_key = lodf |> LODF.branch_keys() |> Enum.with_index() |> Map.new()
    Enum.flat_map(keys, fn key -> List.wrap(Map.get(by_key, key)) end)
  end
end
