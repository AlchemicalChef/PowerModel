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
  """

  import Ecto.Query

  alias PowerModel.{Demand, Grid, Repo}
  alias PowerModel.Failure.Cascade
  alias PowerModel.Grid.{Interconnection, TransmissionLine, Transformer}
  alias PowerModel.Solver.{DCPowerFlow, Partition}

  require Logger

  @default_threshold 0.8
  @default_max_circuits 8
  @default_passes 8
  @base_mva 100.0

  @loading_bins [100, 150, 200, 300, 500]

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

  Options: `:threshold`, `:max_circuits`, `:passes`, `:base_mva`.
  """
  def infer(snapshot, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    max_circuits = Keyword.get(opts, :max_circuits, @default_max_circuits)
    passes = Keyword.get(opts, :passes, @default_passes)
    base_mva = Keyword.get(opts, :base_mva, @base_mva)

    {snapshot, circuits, over_cap, pass_log} =
      Enum.reduce_while(1..passes, {snapshot, %{}, %{}, []}, fn pass,
                                                                {snap, circuits, over_cap, log} ->
        solution = DCPowerFlow.solve_islands(snap, base_mva: base_mva)

        needs =
          solution.line_flows
          |> Enum.filter(fn {_key, f} -> rated?(f) and f.loading_pct > threshold * 100.0 end)
          |> Map.new(fn {key, f} -> {key, ceil(f.loading_pct / (threshold * 100.0) - 1.0e-9)} end)

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

    report = %{
      threshold: threshold,
      max_circuits: max_circuits,
      branches: map_size(circuits),
      extra_circuits: circuits |> Map.values() |> Enum.map(&(&1 - 1)) |> Enum.sum(),
      circuits: circuits,
      over_cap: over_cap,
      passes: Enum.reverse(pass_log)
    }

    {stamp_circuits(snapshot, circuits), report}
  end

  defp rated?(f), do: is_number(f.rating_mva) and f.rating_mva > 0.0

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
  # The database pass
  # ---------------------------------------------------------------------------

  @doc """
  Infer and WRITE parallel circuits for every interconnection (or `:names`).

  The operating point is the measured dispatch at each hour in `:hours`
  (default: the peak demand hour in the ingested record and the latest one —
  the capacity a grid is built for, and the hour everything else here is
  measured at); a branch gets the largest count any hour asks for. The pass
  first UNFOLDS the circuits a previous run stored, so it is idempotent and
  can be re-run after any change to the network.

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
        state = Cascade.init(snap, @base_mva, hour: hour)

        {subs, _dead} =
          Partition.split(%{
            buses: state.buses,
            lines: state.lines,
            transformers: state.transformers,
            generators: Cascade.dispatched_generators(state),
            loads: state.loads
          })

        Enum.reduce(subs, acc, fn island, acc ->
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

    written = write_circuits(requirements)

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

  defp write_circuits(requirements) do
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
                inferred_circuits: ^n
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
                inferred_circuits: ^n
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
