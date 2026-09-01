defmodule PowerModel.Dispatch.Redispatch do
  @moduledoc """
  Transmission-constrained re-dispatch: shift generation until no rated branch
  carries more than its rating (REVIEW EXT-1).

  ## Why

  The model's dispatch is placed by balancing authority and fuel (EIA-930)
  and never asked whether a branch can carry it. The ISOs' markets ask that
  question every five minutes: a security-constrained dispatch moves
  generation until every constraint is at or under its limit, which is why
  ERCOT's Frontera-S. Mission 138 kV binds at exactly 100 % of its limit 480
  times in four days while the raw model carries 222 % on it. Measured
  2026-09-01, the branches this model overloads at rest are, at ERCOT's most
  frequent constraints, the real limits — and the at-rest capacity rule had
  been reading them as missing circuits. Re-dispatch is the mechanism that
  distinguishes the two: what it can relieve is a real limit the grid
  operates at; what it cannot is capacity the model lacks.

  ## What it does

  A generation-shift relief loop on the DC flow, with the sensitivities the
  LODF module already computes: B′ is factorized once; each iteration
  re-solves the DC flow, takes the worst overloaded branch, gets its PTDF row
  in one cached solve, and moves MW from the online units that push flow onto
  it hardest (largest positive sensitivity, above their floor) to the units
  that relieve it most (smallest sensitivity, below their nameplate), in
  equal amounts so the island stays balanced, until the branch is at its
  rating. Units whose net effectiveness is below `@min_effectiveness` are not
  used — a shift that moves 2 MW of flow per 100 MW is not what a market
  would do either. No costs: this is feasibility, the minimum the real grid
  does; economics (ROADMAP's rejected OPF) is a different question.

  Pure: takes an island snapshot whose generators carry the dispatch in
  `p_max_mw` (as `Cascade.dispatched_generators/1` shapes them, with
  `p_nameplate_mw` as the ceiling and `p_min_mw` as the floor when present)
  and returns the same island with shifted generators and a report.
  """

  alias PowerModel.Solver.{DCPowerFlow, LODF}

  require Logger

  @default_target 1.0
  @default_max_iterations 60
  @min_shift_mw 0.5
  @min_effectiveness 0.05

  @doc """
  Relieve every rated-branch overload the DC flow shows, by generation shift.

  Options: `:target` (fraction of rate A to hold, default #{@default_target}),
  `:max_iterations` (default #{@default_max_iterations}), `:base_mva`.

  Returns `{island, report}`:

      %{iterations:, shifted_mw:, relieved: [%{branch:, before_mw:, after_mw:, rating_mva:}],
        residual: [%{branch:, mw:, rating_mva:}], stopped: :clean | :ineffective | :cap | :lodf_error}
  """
  def relieve(island, opts \\ []) do
    target = Keyword.get(opts, :target, @default_target)
    max_iter = Keyword.get(opts, :max_iterations, @default_max_iterations)
    base_mva = Keyword.get(opts, :base_mva, 100.0)

    dc0 = DCPowerFlow.solve(island, base_mva: base_mva)

    case LODF.init(island, dc0, base_mva: base_mva) do
      {:ok, lodf} ->
        loop(island, lodf, target, max_iter, base_mva, 0, 0.0, %{}, dc0)

      {:error, reason} ->
        Logger.warning("redispatch: LODF init failed (#{inspect(reason)}); nothing shifted")

        {island,
         %{
           iterations: 0,
           shifted_mw: 0.0,
           relieved: [],
           residual: overloads(dc0, target),
           stopped: :lodf_error
         }}
    end
  end

  defp loop(island, lodf, target, max_iter, base_mva, iter, shifted, before, dc) do
    over = overloads(dc, target)

    cond do
      over == [] ->
        {island, finish(:clean, iter, shifted, before, dc, target)}

      iter >= max_iter ->
        {island, finish(:cap, iter, shifted, before, dc, target)}

      true ->
        %{branch: key, mw: flow_mw} = hd(over)
        before = Map.put_new(before, key, flow_mw)

        case shift_for(island, lodf, key, dc, target) do
          {:ok, island, moved} when moved > 0.0 ->
            dc = DCPowerFlow.solve(island, base_mva: base_mva)
            loop(island, lodf, target, max_iter, base_mva, iter + 1, shifted + moved, before, dc)

          _ ->
            {island, finish(:ineffective, iter, shifted, before, dc, target)}
        end
    end
  end

  # Rated branches over the target, worst first, with signed flow.
  defp overloads(dc, target) do
    dc.line_flows
    |> Enum.filter(fn {_k, f} ->
      is_number(f.rating_mva) and f.rating_mva > 0.0 and abs(f.p_flow_mw) > target * f.rating_mva
    end)
    |> Enum.map(fn {k, f} ->
      %{
        branch: k,
        mw: f.p_flow_mw,
        rating_mva: f.rating_mva,
        over_mw: abs(f.p_flow_mw) - target * f.rating_mva
      }
    end)
    |> Enum.sort_by(&(-&1.over_mw))
  end

  defp finish(stopped, iter, shifted, before, dc, target) do
    residual = overloads(dc, target)
    residual_keys = MapSet.new(residual, & &1.branch)

    relieved =
      before
      |> Enum.reject(fn {k, _} -> MapSet.member?(residual_keys, k) end)
      |> Enum.map(fn {k, mw0} ->
        f = dc.line_flows[k]
        %{branch: k, before_mw: mw0, after_mw: f && f.p_flow_mw, rating_mva: f && f.rating_mva}
      end)

    %{
      iterations: iter,
      shifted_mw: shifted,
      relieved: relieved,
      residual: Enum.map(residual, &Map.take(&1, [:branch, :mw, :rating_mva])),
      stopped: stopped
    }
  end

  # One relief step for branch `key`: pair the most flow-pushing units with
  # the most relieving ones until the overload is covered.
  defp shift_for(island, lodf, key, dc, target) do
    f = dc.line_flows[key]
    need = abs(f.p_flow_mw) - target * f.rating_mva
    sign = if f.p_flow_mw >= 0.0, do: 1.0, else: -1.0

    with pos when is_integer(pos) <- Map.get(lodf.pos_by_key, key),
         {:ok, [{_pos, x, _denom}]} <- LODF.sensitivity_batch(lodf, [pos]) do
      b = elem(lodf.branches, pos)
      reduced = reduced_index(lodf)

      # Sensitivity of this branch's (signed toward the overload) flow to an
      # injection at the unit's bus, in MW per MW.
      eff = fn gen ->
        case Map.get(reduced, gen.bus_id) do
          nil -> 0.0
          ri -> sign * b.b * elem(x, ri)
        end
      end

      gens = Enum.with_index(island.generators)

      decs =
        gens
        |> Enum.map(fn {g, i} -> {eff.(g), g, i} end)
        |> Enum.filter(fn {_e, g, _} ->
          (g.p_max_mw || 0.0) > floor_mw(g) + @min_shift_mw
        end)
        |> Enum.sort_by(fn {e, _, _} -> -e end)

      incs =
        gens
        |> Enum.map(fn {g, i} -> {eff.(g), g, i} end)
        |> Enum.filter(fn {_e, g, _} -> ceiling_mw(g) > (g.p_max_mw || 0.0) + @min_shift_mw end)
        |> Enum.sort_by(fn {e, _, _} -> e end)

      {moves, moved} = pair(decs, incs, need, %{}, 0.0)

      if moved <= 0.0 do
        {:ok, island, 0.0}
      else
        generators =
          island.generators
          |> Enum.with_index()
          |> Enum.map(fn {g, i} ->
            case Map.get(moves, i) do
              nil -> g
              d -> %{g | p_max_mw: (g.p_max_mw || 0.0) + d}
            end
          end)

        {:ok, %{island | generators: generators}, moved}
      end
    else
      _ -> {:ok, island, 0.0}
    end
  end

  # Greedy pairing: best decreaser with best increaser, bounded by their room
  # and by the remaining need; a pair below @min_effectiveness ends it.
  defp pair([], _incs, _need, moves, moved), do: {moves, moved}
  defp pair(_decs, [], _need, moves, moved), do: {moves, moved}
  defp pair(_decs, _incs, need, moves, moved) when need <= 0.0, do: {moves, moved}

  defp pair([{ed, gd, id} | decs], [{ei, gi, ii} | incs], need, moves, moved) do
    effectiveness = ed - ei

    if effectiveness < @min_effectiveness or gd.id == gi.id do
      {moves, moved}
    else
      room_d = (gd.p_max_mw || 0.0) + Map.get(moves, id, 0.0) - floor_mw(gd)
      room_i = ceiling_mw(gi) - ((gi.p_max_mw || 0.0) + Map.get(moves, ii, 0.0))
      dp = Enum.min([need / effectiveness, room_d, room_i])

      if dp < @min_shift_mw do
        # Whichever side is exhausted moves on.
        if room_d <= room_i,
          do: pair(decs, [{ei, gi, ii} | incs], need, moves, moved),
          else: pair([{ed, gd, id} | decs], incs, need, moves, moved)
      else
        moves = moves |> Map.update(id, -dp, &(&1 - dp)) |> Map.update(ii, dp, &(&1 + dp))
        need = need - dp * effectiveness
        decs = if room_d - dp > @min_shift_mw, do: [{ed, gd, id} | decs], else: decs
        incs = if room_i - dp > @min_shift_mw, do: [{ei, gi, ii} | incs], else: incs
        pair(decs, incs, need, moves, moved + dp)
      end
    end
  end

  defp floor_mw(g), do: max(Map.get(g, :p_min_mw) || 0.0, 0.0)

  defp ceiling_mw(g) do
    cap = Map.get(g, :p_nameplate_mw) || Map.get(g, :summer_capacity_mw) || g.p_max_mw || 0.0
    max(cap, g.p_max_mw || 0.0)
  end

  # bus id -> reduced (slack-eliminated) index, as the LODF solves use.
  defp reduced_index(lodf) do
    Map.new(lodf.bus_index, fn {bus_id, i} ->
      cond do
        i == lodf.slack_idx -> {bus_id, nil}
        i > lodf.slack_idx -> {bus_id, i - 1}
        true -> {bus_id, i}
      end
    end)
    |> Enum.reject(fn {_b, ri} -> is_nil(ri) end)
    |> Map.new()
  end
end
