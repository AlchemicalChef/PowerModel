defmodule Mix.Tasks.PowerModel.ReactiveStudy do
  @moduledoc """
  Re-derive `priv/reactive_planning/reactive_support_banks.json` — the
  generator reactive support study `Ingestion.ParameterEstimator` reads.

      mix power_model.reactive_study
      mix power_model.reactive_study --out /tmp/study.json
      mix power_model.reactive_study --interconnection ERCOT

  ## Why this task exists

  The study is a MEASURED planning result: which generator buses run out of
  reactive production is a property of the solved network, so finding them
  takes a power flow. It was carried as committed data with a documented
  basis but NO producer (REVIEW DAT-31) — the harness that derived it lived in
  a session scratchpad, twice. A measured artifact nobody can regenerate goes
  stale silently, and the study must be re-derived after ANY change to voltage
  data, because `buses.source_id` embeds the voltage and a restamp renames the
  bus the bank is keyed to (REVIEW DAT-30).

  ## Method

  Per interconnection, on the largest island of `Solver.Partition.split/1`:

    1. **Control the network to reactors only.** The study measures a
       shortfall that the banks then supply, so deriving it on a network that
       already has those banks would measure the residual and shrink the study
       on every re-run. `capacitor_bank_targets/1` is subtracted from stored
       `bs_mvar` IN MEMORY; the database is not written.
    2. **Bisect alpha to 0.01** — the highest uniform scaling of hour-scaled
       load P/Q and generator dispatch at which an AC solution exists.
    3. **Solve twice at that alpha**: once as-is, once with every generator's
       q limits multiplied by ten (the `qmax10` lever). A bus PINNED at q_max
       in the base solve whose free output is higher wants that difference.
    4. **Shortfall = q_free - q_max**, recorded per bus with the voltage it
       sat at. Not a multiple of q_max: a pinned bus the network wants no more
       vars from gets no bank.

  Both solves must converge or the task raises — shortfalls read off a
  non-converged solve are noise, and writing them would look like data.

  ## What it stamps

  `Grid.network_signature/0` goes into the artifact as `inputs`, so a later
  run of the estimator can tell whether the network moved underneath the
  study. Alpha is well below 1.0, so these shortfalls are measured on a
  lightly loaded network and are conservative.
  """

  use Mix.Task

  require Logger

  alias PowerModel.{Demand, Grid, Repo}
  alias PowerModel.Failure.Cascade
  alias PowerModel.Ingestion.ParameterEstimator
  alias PowerModel.Solver.{FDPF, LoadModel, NewtonRaphson, Partition}

  @shortdoc "Re-derive the generator reactive support study"

  @base_mva 100.0
  @qmax_lever 10.0
  @bisection_steps 7
  @solve_opts [base_mva: @base_mva, dense_nr_max_buses: 0, max_iterations: 400]

  @switches [out: :string, interconnection: :keep, hour: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [],
      do: Mix.raise("unrecognised option(s): #{inspect(Enum.map(invalid, &elem(&1, 0)))}")

    Mix.Task.run("app.start")
    Logger.configure(level: :warning)

    hour = parse_hour(opts[:hour]) || Demand.latest_demand_hour()
    out = Keyword.get(opts, :out, ParameterEstimator.generator_support_study_path())

    interconnections =
      case Keyword.get_values(opts, :interconnection) do
        [] -> Grid.list_interconnections()
        given -> Enum.map(given, &fetch_interconnection!/1)
      end

    Mix.shell().info("Reactive support study — hour #{inspect(hour)}")

    {caps_now, _load_buses, _support} = ParameterEstimator.capacitor_bank_targets()

    Mix.shell().info(
      "  controlling out #{map_size(caps_now)} existing capacitor buses " <>
        "(#{round(Enum.sum(Map.values(caps_now)))} MVAr) to measure on reactors only"
    )

    results = Enum.map(interconnections, &study_one(&1, hour, caps_now))

    study = %{
      "study" => "generator reactive support banks",
      "measured_on" => Date.utc_today() |> Date.to_iso8601(),
      "generated_by" => "mix power_model.reactive_study",
      "inputs" => stringify(Grid.network_signature()),
      "counts" => Map.new(results, &{&1.ic, &1.counts}),
      "basis" => basis(hour, results),
      "banks" => Enum.flat_map(results, & &1.banks)
    }

    File.mkdir_p!(Path.dirname(out))
    File.write!(out, Jason.encode_to_iodata!(study, pretty: true))
    Mix.shell().info("\nWrote #{length(study["banks"])} banks to #{out}")

    Enum.each(results, fn r ->
      Mix.shell().info(
        "  #{r.ic}: alpha #{r.alpha}, #{r.counts["pinned_qmax"]} pinned of " <>
          "#{r.counts["gen_buses"]} gen buses, #{r.counts["with_shortfall"]} banks, " <>
          "#{r.counts["total_shortfall_mvar"]} MVAr"
      )
    end)

    Mix.shell().info("\nApply with: mix power_model.ingest estimate_parameters")
  end

  defp study_one(ic, hour, caps_now) do
    Mix.shell().info("\n── #{ic.name} ──")

    island = island_for(ic, hour)

    control = %{
      island
      | buses:
          Enum.map(island.buses, fn b ->
            %{b | bs_mvar: (b.bs_mvar || 0.0) - Map.get(caps_now, b.id, 0.0)}
          end)
    }

    alpha = ceiling(control)
    Mix.shell().info("  alpha ceiling (reactors only): #{alpha}")

    scaled = scale(control, alpha)
    base_sol = solve!(scaled, "base solve at the ceiling")
    lifted = qmax_lever(scaled, @qmax_lever)
    free_sol = solve!(lifted, "qmax#{trunc(@qmax_lever)} solve at the ceiling")

    q_base = gen_q_by_bus(scaled, base_sol)
    q_free = gen_q_by_bus(lifted, free_sol)

    q_max_by_bus =
      island.generators
      |> Enum.group_by(& &1.bus_id)
      |> Map.new(fn {bus, gs} ->
        {bus, Enum.sum(Enum.map(gs, &(Map.get(&1, :q_max_mvar) || 0.0)))}
      end)

    vm = Map.new(Enum.zip(base_sol.bus_ids, base_sol.vm_pu))
    bus_rows = Map.new(island.buses, &{&1.id, &1})

    pinned =
      Enum.filter(q_base, fn {bus, q} ->
        qm = Map.get(q_max_by_bus, bus, 0.0)
        qm > 0.0 and q >= qm - 0.5
      end)

    banks =
      Enum.flat_map(pinned, fn {bus, _q} ->
        qm = Map.get(q_max_by_bus, bus, 0.0)
        shortfall = Map.get(q_free, bus, qm) - qm
        b = Map.get(bus_rows, bus)

        if shortfall > 0.0 and b do
          [
            %{
              "source" => b.source,
              "source_id" => b.source_id,
              "interconnection" => ic.name,
              "base_kv" => b.base_kv,
              "vm_pu" => Float.round(Map.get(vm, bus, 1.0), 4),
              "shortfall_mvar" => Float.round(shortfall, 3),
              "q_max_mvar" => Float.round(qm, 3)
            }
          ]
        else
          []
        end
      end)

    %{
      ic: ic.name,
      alpha: alpha,
      banks: banks,
      counts: %{
        "gen_buses" => map_size(q_base),
        "pinned_qmax" => length(pinned),
        "with_shortfall" => length(banks),
        "total_shortfall_mvar" =>
          banks |> Enum.map(& &1["shortfall_mvar"]) |> Enum.sum() |> Float.round(1)
      }
    }
  end

  defp island_for(ic, hour) do
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

    Enum.max_by(subs, &length(&1.buses))
  end

  defp scale(island, a) do
    %{
      island
      | loads:
          Enum.map(island.loads, &%{&1 | p_mw: (&1.p_mw || 0.0) * a, q_mvar: (&1.q_mvar || 0.0) * a}),
        generators: Enum.map(island.generators, &%{&1 | p_max_mw: &1.p_max_mw * a})
    }
  end

  defp qmax_lever(island, mult) do
    %{
      island
      | generators:
          Enum.map(island.generators, fn g ->
            %{
              g
              | q_max_mvar: (Map.get(g, :q_max_mvar) || 0.0) * mult,
                q_min_mvar: (Map.get(g, :q_min_mvar) || 0.0) * mult
            }
          end)
    }
  end

  defp converges?(island, a) do
    case FDPF.solve(scale(island, a), @solve_opts) do
      {:ok, s} -> s.converged
      _ -> false
    end
  catch
    _, _ -> false
  end

  defp ceiling(island) do
    if converges?(island, 1.0) do
      1.0
    else
      1..@bisection_steps
      |> Enum.reduce({0.0, 1.0}, fn _, {lo, hi} ->
        mid = (lo + hi) / 2
        if converges?(island, mid), do: {mid, hi}, else: {lo, mid}
      end)
      |> elem(0)
      |> Float.round(4)
    end
  end

  defp solve!(island, label) do
    {:ok, sol} = FDPF.solve(island, @solve_opts)

    unless sol.converged do
      Mix.raise(
        "#{label} did not converge — shortfalls read off it would be noise, not data. " <>
          "Check the network before re-running."
      )
    end

    sol
  end

  # Generator reactive output per bus, in MVAr, at a solved point.
  # injection = gen - load, so gen = injection + load.
  defp gen_q_by_bus(island, sol) do
    prep = NewtonRaphson.prepare(island, base_mva: @base_mva)
    vm = :array.from_list(sol.vm_pu)
    va = :array.from_list(sol.va_rad)
    {_p, q_calc} = NewtonRaphson.power_injections(prep.y_sparse, vm, va)

    q_load =
      Map.new(prep.bus_loads, fn {idx, loads} ->
        v = :array.get(idx, vm)

        {idx,
         Enum.reduce(loads, 0.0, fn l, acc ->
           {_p, q} = LoadModel.effective_load(l, v, prep.load_compensation)
           acc + q
         end)}
      end)

    prep.generators
    |> Enum.map(&Map.fetch!(prep.bus_index, &1.bus_id))
    |> Enum.uniq()
    |> Map.new(fn idx ->
      {Enum.at(prep.bus_ids, idx),
       @base_mva * :array.get(idx, q_calc) + Map.get(q_load, idx, 0.0)}
    end)
  end

  defp basis(hour, results) do
    %{
      "hour" => "Demand.latest_demand_hour/0 (#{inspect(hour)})",
      "snapshot" =>
        "Grid.get_grid_snapshot(ic.id, hour: hour) -> Cascade.init(snap, 100.0, hour: hour) -> " <>
          "dispatched_generators/1; largest island of Solver.Partition.split/1",
      "control" =>
        "reactors only: stored bs_mvar minus ParameterEstimator.capacitor_bank_targets/1, " <>
          "applied in memory. Deriving on a network that already carries the banks would " <>
          "measure the residual and shrink the study on every re-run.",
      "solver" => "FDPF.solve(#{inspect(@solve_opts)})",
      "vm_pu" => "bus voltage in the BASE solve at that alpha",
      "alpha" => Map.new(results, &{&1.ic, &1.alpha}),
      "shortfall" =>
        "q_free - q_max, where q_free is the bus's reactive output with generator q_max " <>
          "x#{trunc(@qmax_lever)} at the same alpha. Only buses PINNED at q_max in the base " <>
          "solve are listed.",
      "note" =>
        "alpha is each island's AC loadability ceiling. It is well below 1.0, so these " <>
          "shortfalls are measured on a lightly loaded network and are conservative."
    }
  end

  defp stringify(%{counts: counts, digest: digest}) do
    %{
      "counts" => Map.new(counts, fn {k, v} -> {to_string(k), v} end),
      "digest" => Map.new(digest, fn {k, v} -> {to_string(k), v} end)
    }
  end

  defp parse_hour(nil), do: nil

  defp parse_hour(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      {:error, reason} -> Mix.raise("--hour #{s} is not ISO8601: #{inspect(reason)}")
    end
  end

  defp fetch_interconnection!(name) do
    case Repo.get_by(Grid.Interconnection, name: name) do
      nil -> Mix.raise("no interconnection named #{inspect(name)}")
      ic -> ic
    end
  end
end
