defmodule PowerModel.Test.MATPOWER do
  @moduledoc """
  Parser for MATPOWER `.m` case files, producing the snapshot map that
  `PowerModel.Solver.DCPowerFlow` and `PowerModel.Solver.NewtonRaphson` consume.

  The output shape is exactly the one `PowerModel.Solver.IEEE14BusTest` builds by
  hand — `%{buses:, lines:, transformers:, generators:, loads:}` — so a parsed
  case is a drop-in replacement for a hand-written fixture.

  ## What is read

  `mpc.baseMVA`, `mpc.bus`, `mpc.gen` and `mpc.branch`. Everything else in the
  file (`mpc.gencost`, `mpc.bus_name`, area/interchange blocks, OPF extensions)
  is ignored: the solvers under test do no optimization.

  ## Conventions

  Where MATPOWER's semantics and this codebase's snapshot shape differ, the
  parser resolves it here rather than leaving the solver to guess. Each choice
  below is a decision that changes results, so each is stated explicitly.

  ### Per-unit and units

    * `Pd`/`Qd` (bus) and `Pg`/`Qg`/`Qmax`/`Qmin` (gen) are in MW/MVAr on the
      system base and are passed through unscaled — the snapshot carries MW.
    * `r`, `x`, `b` (branch) are already per-unit on `baseMVA`, passed through.
    * `Gs`/`Bs` (bus) are MW/MVAr consumed/injected at V = 1.0 pu, which is what
      `YBus.build/4` expects for `gs_mw`/`bs_mvar`.

  ### Bus types

  MATPOWER's `bustypes/2` requires an **in-service generator** for a bus to be
  PV or REF: a type-2 bus whose only generators are out of service is solved as
  PQ. `NewtonRaphson.classify_buses/3` instead treats `bus_type == 2` as PV
  unconditionally, so this parser demotes such orphaned PV buses to type 1
  before the solver sees them. Without the demotion the two tools solve
  different problems — `case_ACTIVSg2000` has 93 such buses.

  The mirror case (a type-1 bus carrying an in-service generator, which
  MATPOWER solves as PQ but this codebase would promote to PV) is reported in
  `:pq_buses_with_generators`. Neither shipped fixture contains one; if a case
  does, its results will not match a MATPOWER reference and the count says so.

  ### Voltage setpoints

  MATPOWER's `runpf` overwrites the bus voltage magnitude with the generator's
  `Vg` at every generator bus. The parser does the same, so `bus.vm_pu` — which
  is what `NewtonRaphson.scheduled_voltages/4` reads — carries `Vg`, not the
  bus's own `VM` column. The two differ by up to 0.035 pu in
  `case_ACTIVSg2000`.

  ### Branches

  A branch becomes a **transformer** when its tap ratio is neither 0 nor 1, or
  its phase shift is nonzero; otherwise it is a **line**. This split is forced
  by the solvers' branch models, which are not interchangeable:

    * the line model carries the charging susceptance `b` (half at each end)
      and matches MATPOWER's pi model exactly when `tap == 1`;
    * the transformer model applies the tap ratio but **drops `b` entirely**.

  So a tapped branch with nonzero charging would lose that charging. The parser
  counts such branches in `:transformers_with_dropped_charging` rather than
  silently discarding the data. Both shipped fixtures report 0.

  MATPOWER writes `tap = 0` to mean "no transformer, ratio 1"; that is
  normalized to 1.

  ### Phase shifters are skipped

  This codebase has no phase-shift representation anywhere: neither `YBus`
  nor `DCPowerFlow` carries a shift angle, and folding a nonzero shift into an
  unshifted branch would silently move real power. Branches with a nonzero
  `SHIFT` are therefore **omitted from the snapshot** and counted in
  `:skipped_phase_shifters`. Omitting a branch changes the network, so any case
  with a nonzero count cannot be compared against a MATPOWER reference — the
  tests assert the count is zero. Both shipped fixtures are free of phase
  shifters.

  ### Out-of-service equipment

  Generators and branches with status <= 0 are dropped, matching MATPOWER.
  Out-of-service *buses* (type 4, isolated) are also dropped, along with any
  branch, generator or load attached to them.

  ### Loads

  One load entry per bus with nonzero `Pd` or `Qd`. No `:load_type` is set, so
  `LoadModel` treats them as constant power — MATPOWER's only load model.

  ## Example

      snapshot = PowerModel.Test.MATPOWER.load!("test/fixtures/matpower/case118.m")
      solution = PowerModel.Solver.DCPowerFlow.solve(snapshot, base_mva: snapshot.base_mva)
  """

  # MATPOWER column indices (1-based, per CASEFORMAT).
  @bus_i 1
  @bus_type 2
  @bus_pd 3
  @bus_qd 4
  @bus_gs 5
  @bus_bs 6
  @bus_vm 8
  @bus_base_kv 10

  @gen_bus 1
  @gen_pg 2
  @gen_qmax 4
  @gen_qmin 5
  @gen_vg 6
  @gen_status 8

  @br_f_bus 1
  @br_t_bus 2
  @br_r 3
  @br_x 4
  @br_b 5
  @br_rate_a 6
  @br_tap 9
  @br_shift 10
  @br_status 11

  @doc """
  Parse a MATPOWER case file into a solver snapshot.

  Returns a map carrying the five snapshot lists plus parse metadata:

    * `:base_mva` — `mpc.baseMVA`, to pass as the solvers' `:base_mva` option
    * `:case_name` — the name from the `function mpc = <name>` header
    * `:skipped_phase_shifters` — branches dropped for having a nonzero shift
    * `:transformers_with_dropped_charging` — tapped branches whose `b` the
      transformer model cannot represent
    * `:demoted_pv_buses` — type-2 buses retyped to PQ for having no in-service
      generator
    * `:pq_buses_with_generators` — type-1 buses carrying an in-service
      generator, which this codebase will solve as PV and MATPOWER as PQ
    * `:isolated_buses` — type-4 buses dropped

  Raises `ArgumentError` if the file cannot be parsed.
  """
  @spec load!(Path.t()) :: map()
  def load!(path) do
    path |> File.read!() |> parse!(Path.basename(path))
  end

  @doc "Parse MATPOWER case text. See `load!/1`."
  @spec parse!(String.t(), String.t()) :: map()
  def parse!(text, source \\ "<string>") do
    base_mva = parse_base_mva!(text, source)
    bus_rows = parse_matrix!(text, "bus", source)
    gen_rows = parse_matrix!(text, "gen", source)
    branch_rows = parse_matrix!(text, "branch", source)

    {live_bus_rows, isolated} = Enum.split_with(bus_rows, &(col(&1, @bus_type) != 4))
    live_bus_ids = MapSet.new(live_bus_rows, &bus_id(&1, @bus_i))

    live_gens =
      gen_rows
      |> Enum.filter(&(col(&1, @gen_status) > 0))
      |> Enum.filter(&MapSet.member?(live_bus_ids, bus_id(&1, @gen_bus)))

    # MATPOWER's Vg overrides the bus VM column at generator buses. Where a bus
    # carries several generators, MATLAB's vectorized assignment lets the last
    # row win; Map.new/2 keeps the last value for a duplicate key, so the two
    # agree. (Neither shipped fixture has generators disagreeing on Vg.)
    vg_by_bus = Map.new(live_gens, &{bus_id(&1, @gen_bus), col(&1, @gen_vg)})
    gen_bus_ids = MapSet.new(Map.keys(vg_by_bus))

    buses = build_buses(live_bus_rows, vg_by_bus)
    loads = build_loads(live_bus_rows)
    generators = build_generators(live_gens)

    {lines, transformers, shifters, dropped_charging} =
      build_branches(branch_rows, live_bus_ids)

    %{
      base_mva: base_mva,
      case_name: parse_case_name(text),
      buses: buses,
      lines: lines,
      transformers: transformers,
      generators: generators,
      loads: loads,
      skipped_phase_shifters: shifters,
      transformers_with_dropped_charging: dropped_charging,
      demoted_pv_buses:
        Enum.count(live_bus_rows, fn r ->
          col(r, @bus_type) == 2 and not MapSet.member?(gen_bus_ids, bus_id(r, @bus_i))
        end),
      pq_buses_with_generators:
        Enum.count(live_bus_rows, fn r ->
          col(r, @bus_type) == 1 and MapSet.member?(gen_bus_ids, bus_id(r, @bus_i))
        end),
      isolated_buses: length(isolated)
    }
  end

  # ── Buses ───────────────────────────────────────────────────────────────

  defp build_buses(bus_rows, vg_by_bus) do
    Enum.map(bus_rows, fn row ->
      id = bus_id(row, @bus_i)

      # A type-2 bus with no in-service generator has nothing holding its
      # voltage; MATPOWER solves it as PQ and so must this snapshot.
      bus_type =
        case trunc(col(row, @bus_type)) do
          2 -> if Map.has_key?(vg_by_bus, id), do: 2, else: 1
          other -> other
        end

      %{
        id: id,
        bus_type: bus_type,
        base_kv: col(row, @bus_base_kv),
        vm_pu: Map.get(vg_by_bus, id, col(row, @bus_vm)),
        va_rad: 0.0,
        gs_mw: col(row, @bus_gs),
        bs_mvar: col(row, @bus_bs)
      }
    end)
  end

  defp build_loads(bus_rows) do
    bus_rows
    |> Enum.filter(&(col(&1, @bus_pd) != 0.0 or col(&1, @bus_qd) != 0.0))
    |> Enum.with_index(1)
    |> Enum.map(fn {row, idx} ->
      %{
        id: idx,
        bus_id: bus_id(row, @bus_i),
        p_mw: col(row, @bus_pd),
        q_mvar: col(row, @bus_qd)
      }
    end)
  end

  # ── Generators ──────────────────────────────────────────────────────────

  # p_max_mw carries the *dispatched* Pg, not the Pmax column: the solvers
  # inject `p_max_mw * capacity_factor`, so the scheduled operating point has to
  # arrive as p_max_mw with capacity_factor pinned to 1.0. Pmax/Pmin are OPF
  # limits and would be the wrong injection.
  defp build_generators(gen_rows) do
    gen_rows
    |> Enum.with_index(1)
    |> Enum.map(fn {row, idx} ->
      %{
        id: idx,
        bus_id: bus_id(row, @gen_bus),
        p_max_mw: col(row, @gen_pg),
        capacity_factor: 1.0,
        q_max_mvar: col(row, @gen_qmax),
        q_min_mvar: col(row, @gen_qmin)
      }
    end)
  end

  # ── Branches ────────────────────────────────────────────────────────────

  defp build_branches(branch_rows, live_bus_ids) do
    in_service =
      branch_rows
      |> Enum.filter(&(col(&1, @br_status) > 0))
      |> Enum.filter(fn row ->
        MapSet.member?(live_bus_ids, bus_id(row, @br_f_bus)) and
          MapSet.member?(live_bus_ids, bus_id(row, @br_t_bus))
      end)

    {shifters, unshifted} = Enum.split_with(in_service, &(col(&1, @br_shift) != 0.0))
    {tapped, plain} = Enum.split_with(unshifted, &(tap_ratio(&1) != 1.0))

    lines =
      plain
      |> Enum.with_index(1)
      |> Enum.map(fn {row, idx} ->
        %{
          id: idx,
          from_bus_id: bus_id(row, @br_f_bus),
          to_bus_id: bus_id(row, @br_t_bus),
          voltage_kv: nil,
          r_pu: col(row, @br_r),
          x_pu: col(row, @br_x),
          b_pu: col(row, @br_b),
          rating_a_mva: rating(col(row, @br_rate_a))
        }
      end)

    transformers =
      tapped
      |> Enum.with_index(1)
      |> Enum.map(fn {row, idx} ->
        %{
          id: idx,
          from_bus_id: bus_id(row, @br_f_bus),
          to_bus_id: bus_id(row, @br_t_bus),
          r_pu: col(row, @br_r),
          x_pu: col(row, @br_x),
          rated_mva: rating(col(row, @br_rate_a)),
          tap_ratio: tap_ratio(row)
        }
      end)

    {lines, transformers, length(shifters), Enum.count(tapped, &(col(&1, @br_b) != 0.0))}
  end

  # MATPOWER: tap 0 means "not a transformer", i.e. ratio 1. The ratio is
  # defined on the *from* side, which is also where YBus applies it.
  defp tap_ratio(row) do
    tap = col(row, @br_tap)
    if tap > 0.0, do: tap, else: 1.0
  end

  # rateA = 0 means "unlimited" in MATPOWER. The solvers treat a nil rating as
  # unrated (loading 0%, never overloaded), which is the honest rendering; 0.0
  # would be read as a real zero-capacity branch by `rated?`.
  defp rating(rate) when rate > 0.0, do: rate
  defp rating(_), do: nil

  # ── Lexing ──────────────────────────────────────────────────────────────

  defp parse_base_mva!(text, source) do
    case Regex.run(~r/mpc\.baseMVA\s*=\s*([\d.eE+-]+)\s*;/, text) do
      [_, value] ->
        to_float!(value, "baseMVA", source)

      nil ->
        raise ArgumentError, "#{source}: no `mpc.baseMVA = ...;` assignment found"
    end
  end

  defp parse_case_name(text) do
    case Regex.run(~r/function\s+mpc\s*=\s*(\w+)/, text) do
      [_, name] -> name
      nil -> nil
    end
  end

  # Matches `mpc.<name> = [ ... ];` where the closing bracket starts a line, so
  # a `];` appearing inside a comment cannot end the block early.
  defp parse_matrix!(text, name, source) do
    case Regex.run(~r/mpc\.#{name}\s*=\s*\[(.*?)\n\s*\];/s, text) do
      nil ->
        raise ArgumentError, "#{source}: no `mpc.#{name} = [...];` block found"

      [_, body] ->
        rows =
          body
          |> String.split("\n")
          |> Enum.map(&strip_comment/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&parse_row!(&1, name, source))

        if rows == [] do
          raise ArgumentError, "#{source}: `mpc.#{name}` block is empty"
        end

        rows
    end
  end

  defp strip_comment(line) do
    line |> String.split("%", parts: 2) |> hd() |> String.trim() |> String.trim_trailing(";")
  end

  defp parse_row!(line, name, source) do
    line
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.map(&to_float!(&1, "mpc.#{name} row `#{line}`", source))
    |> :array.from_list()
  end

  # Float.parse handles both integer literals ("1") and exponents ("34e12"),
  # which covers every numeric form MATPOWER writes.
  defp to_float!(token, context, source) do
    case Float.parse(token) do
      {value, ""} -> value
      _ -> raise ArgumentError, "#{source}: cannot parse #{inspect(token)} in #{context}"
    end
  end

  # 1-based column access against the 0-based :array row.
  defp col(row, index), do: :array.get(index - 1, row)

  defp bus_id(row, index), do: trunc(col(row, index))
end
