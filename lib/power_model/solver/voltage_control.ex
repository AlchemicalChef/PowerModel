defmodule PowerModel.Solver.VoltageControl do
  @moduledoc """
  Controllable reactive plant — switched shunts and load-tap-changing (LTC)
  transformers — as an outer loop around the AC power flow.

  ## Why this exists (REVIEW CAS-28)

  Measured 2026-08-23, no interconnection can hold every bus inside the normal
  0.95–1.05 pu band at ANY uniform load scaling, and Western cannot hold the
  0.90–1.10 emergency band at any scaling either. The network fails from both
  ends: at light load it overvolts on line charging (Western reaches 1.5 pu as
  α → 0), at heavy load the 33–115 kV load buses sag below 0.90. That is not a
  data defect in the branches. It is the absence of the equipment a real
  system uses to hold a profile ACROSS load levels: capacitor banks that switch
  in as load rises, reactors that switch in as it falls, and tap changers that
  hold the subtransmission side wherever the EHV side happens to sit. Fixed
  `bs_mvar` cannot represent any of them — `ParameterEstimator` measured that a
  peak-sized fixed bank destroys the light-load solve, and that is why its
  load-bus banks ship OFF. A device that tracks load is a switched device, and
  this module is where those live.

  ## What it does

  `solve/2` runs `FDPF.solve/2`, reads the converged voltages, moves every
  device whose controlled bus is outside its band by one discrete step (a shunt
  step or a tap position), and solves again from the previous voltages,
  until nothing wants to move or a round cap is hit. The result is an ordinary
  `Solution` with a `:voltage_control` summary and the final device positions,
  so a caller (the cascade) can carry positions forward — real plant does not
  reset between steps.

  Devices are ordinary maps and can be handed in through `:devices`; when they
  are not, `devices/2` derives them from the snapshot by rule:

    * **LTC** on every in-service transformer that crosses a voltage class,
      controlling its LOWER-voltage bus, unless that bus already holds voltage
      itself (a generator bus — the AVR is the controller there). Every
      transformer in the live model is stamped high side = `from`, so the tap
      sits on the high side and `V_low ≈ V_high / t`; the direction is derived
      per transformer from which end is controlled rather than assumed.
      Range #{"0.90–1.10"}, step 5/8 % (the universal 33-position LTC).
    * **Capacitor steps** at every load bus, sized to the bus's load Q times
      `:peak_multiplier` (the loads a snapshot carries are hour-scaled, and a
      bank is plant sized for peak, not for the hour being solved), in steps of
      half the largest bank built at the class, held to
      `ParameterEstimator.cap_class_ceiling/1`.
    * **Reactor steps** at every bus at or above #{"230"} kV with line charging,
      sized so that all steps in bring the bus's incident charging to full
      compensation.
    * **The shunt plant already stamped on the bus is switchable too.** A
      positive `bs_mvar` (a capacitor bank — in the live model, the
      generator-support banks the reactive study placed) starts with that many
      steps IN and can be switched out at light load; a negative one (a
      line-end reactor) likewise starts in and can be switched out at heavy
      load. That is what the equipment is: a bank is a breaker and a set of
      cans, not a constant. Positions are counted relative to the stamped
      plant, so a solve in which nothing moves is bit-identical to the fixed
      case, and switching the stamped plant fully out is exact to within half
      a step.

  ## Rules that keep it from hunting — every one of them measured

  Discrete controls in an outer loop oscillate unless told not to. Measured on
  Western at α 0.2 (2026-08-31, isolation runs of one device class at a time):

    * reactors alone: 18 steps in, Vm max 1.1268 → 1.0731, out of the normal
      band 97 → 33 buses, settled in one round;
    * LTCs alone at four tap steps per round: out of band 97 → 106 and the EHV
      side RISES (1.1268 → 1.2306) — a tap only redistributes voltage, and
      lowering a light-load low side sheds the load-side absorption the EHV
      side was relying on; at ONE step per round the same taps improve it
      (97 → 66);
    * capacitors alone: eight steps of ≤ 30 MVAr at buses under 0.95 pu and
      FDPF diverged. The buses a bank is wanted at are the weak ones, and a
      class-sized step at a weak bus is a large voltage step.

  Hence the rules:

    1. A device acts only when its bus is OUTSIDE its band — the band is the
       deadband. LTCs run a narrower band than shunts so the fine control
       settles inside the coarse one.
    2. Shunts move first. Taps act only in a round where no shunt wants to
       move: vars are supplied before they are redistributed.
    3. A tap moves ONE position per round.
    4. A capacitor or reactor step is held to `@voltage_step_fraction` of the
       bus's strength, estimated from its self-susceptance (the sum of 1/x
       over its branches): IEEE 1036's voltage-step criterion, applied with
       the only strength estimate a snapshot carries.
    5. A round whose solve diverges is BACKED OFF down a ladder: if taps and
       shunts both moved, the shunts are reverted and the taps retried alone;
       if the shunts moved in both directions, the SUPPLYING moves (capacitor
       in, reactor out) are reverted and the absorbing ones retried alone —
       measured on Western at α 0.2, a round of 8 capacitor steps at weak
       buses and 10 reactor steps at a 500 kV cluster diverged on the caps,
       and latching all 18 together left the cluster at 1.127 pu for the rest
       of the solve; failing that, everything that moved is reverted. A
       reverted shunt is treated as an overshoot (rule 11: step halved), a
       reverted tap is latched. The loop then continues from the last
       converged point.
    6. A move that carries its bus clean ACROSS the band — below it before,
       above it after, or the reverse — is undone: a bank step is halved
       (rule 10), a tap is latched. The
       self-susceptance guard cannot see a weak radial pocket (a bus with
       several short lines inside a pocket that hangs on one long one looks
       strong), and measured on Western at α 0.2 a 16 MVAr step at such a bus
       took it from 0.93 to over 1.4 pu. The controller a utility fits has
       exactly this check.
    7. Taps act upstream first: an LTC holds while the LTC feeding its high
       side wants to move, which is what the longer time delay on a downstream
       tap changer does in practice. Without it, series taps (230/115 over
       115/69) chase each other and latch.
    8. A device that reverses direction more than `@max_reversals` times is
       latched where it stands — the same latch the PV/PQ switching rule uses,
       and for the same reason.
    9. **LTC blocking.** A tap does not raise its low side while its high side
       is below `@ltc_block_below`. Measured with rules 1–8 alone (Western α
       0.2, ERCOT α 0.3–0.6, 2026-08-31): the normal-band count improved but
       the MINIMUM voltage got worse at every point (Western 0.873 → 0.815,
       ERCOT α 0.4 0.900 → 0.818), with 12–26 taps run to their 0.90 limit —
       taps restoring load on a transmission side that cannot supply it, which
       is the LTC voltage-collapse mechanism. Blocking taps on low
       transmission voltage is the countermeasure utilities fit for exactly
       this, and it is the rule here.
    10. **LTC blocking, the other way.** A tap does not LOWER its low side
       while its high side is already above the shunt band. Measured on ERCOT
       at α 0.02 (2026-08-31): 138 kV buses at 1.06 pu in the base case ended
       at 1.157 after control, because the taps under them ran to 1.10 pulling
       their low sides down, which shed the load-side absorption the 138 kV
       side depended on — and nothing below 230 kV carries a reactor. That is
       LTC reverse action at light load, and carried tap positions kept those
       buses over 1.10 at every heavier load level of a continuation scan.
    11. A bank step that overshoots is HALVED rather than abandoned: the
       device's step is split in two (its capacity unchanged) and it tries
       again, down to a `@max_split_factor`-way split, and only then latched. A station
       at a weak bus is built from smaller cans; the class-sized step was the
       guess, not the plant.

  ## What it is not

  A power-flow with taps and shunts inside the Jacobian would converge in one
  solve. This is an outer loop, deliberately: B′ and B″ are refactorized per
  round, which costs a prep per move but changes nothing in the solver and
  keeps every device decision a plain function of a converged operating point,
  which is what makes it testable and what a discrete device physically is.
  """

  alias PowerModel.Ingestion.ParameterEstimator
  alias PowerModel.Solver.{FDPF, Solution}

  require Logger

  @ltc_step 0.00625
  @ltc_min 0.90
  @ltc_max 1.10
  # Tap positions per round. Measured (moduledoc): four per round overshoots
  # — taps interact through the network they share and the aggregate move of
  # two hundred of them is not the sum of their local corrections — while one
  # per round improves the profile. Sixteen rounds to a range limit is the
  # price, and a warm-started round is a few seconds even on Eastern.
  @max_ltc_steps_per_round 1

  # A switching step may not exceed this fraction of the bus's strength
  # (self-susceptance × base MVA), i.e. an estimated 2 % voltage step. The
  # self-susceptance overstates strength — the true Thevenin impedance
  # includes everything beyond the neighbours — so this is a floor on the
  # guard, not a precise criterion.
  @voltage_step_fraction 0.02

  @default_ltc_band {0.975, 1.025}
  @default_shunt_band {0.95, 1.05}

  # LTC blocking thresholds on the HIGH-side voltage (rules 9 and 10): no
  # raising into a low transmission side, no lowering under a high one.
  @ltc_block_below 0.95
  @ltc_block_above 1.05

  # A bank step may be halved this many times before the device is latched
  # (the split factor is 2^n, so 8).
  @max_split_factor 8

  @max_rounds 40
  @max_reversals 2

  # Whether devices may act on the last iterate of an UNCONVERGED solve. Off:
  # measured on Western at α 0.2 (2026-08-31), acting on a diverged iterate
  # moved 58 taps and 38 shunt steps on voltages that were not an operating
  # point, and the next converged round was worse than the base case (out of
  # band 9 → 48). An unconverged iterate says nothing reliable about where
  # the network is sagging. The option stays for experiments.
  @default_unconverged_rounds 0

  @reactor_min_kv 230.0

  # Capacitor switching step by class: half the largest bank normally built at
  # the class (the "max bank" column behind `cap_class_ceiling/1`), so one step
  # sits inside IEEE 1036's 2–3 % voltage-step criterion at ordinary fault
  # levels. A bus whose whole installation is smaller than one class step gets
  # a single step of its own size.
  @cap_step_mvar %{
    34.5 => 3.6,
    69.0 => 12.0,
    115.0 => 30.0,
    138.0 => 30.0,
    161.0 => 30.0,
    230.0 => 75.0,
    345.0 => 125.0,
    500.0 => 150.0,
    765.0 => 150.0
  }

  # Switched shunt reactor unit by class.
  @reactor_step_mvar %{
    230.0 => 25.0,
    345.0 => 50.0,
    500.0 => 100.0,
    765.0 => 150.0
  }

  @min_bank_mvar 1.2

  @doc "LTC tap step, range and default bands, for callers that report them."
  def ltc_step, do: @ltc_step
  def ltc_range, do: {@ltc_min, @ltc_max}
  def default_ltc_band, do: @default_ltc_band
  def default_shunt_band, do: @default_shunt_band
  def max_rounds, do: @max_rounds

  # ---------------------------------------------------------------------------
  # Device derivation
  # ---------------------------------------------------------------------------

  @doc """
  Derive the controllable devices for a snapshot. Pure: a function of the
  snapshot's buses, lines, transformers, generators and loads only.

  Options:

    * `:peak_multiplier` — bank capacity is `peak_multiplier × bus load Q`
      (default 1.0). The census passes the ratio of peak to reference-hour
      demand so that the bank does not change size with the α being solved.
    * `:ltc_band`, `:shunt_band` — `{lo, hi}` in pu.
    * `:ltc` / `:capacitors` / `:reactors` — `false` to leave a class out.
  """
  def devices(snapshot, opts \\ []) do
    ltc_band = Keyword.get(opts, :ltc_band, @default_ltc_band)
    shunt_band = Keyword.get(opts, :shunt_band, @default_shunt_band)
    peak = Keyword.get(opts, :peak_multiplier, 1.0)

    bus_by_id = Map.new(snapshot.buses, &{&1.id, &1})
    gen_buses = MapSet.new(Map.get(snapshot, :generators, []), & &1.bus_id)
    strength = strength_mva(snapshot)

    ltcs =
      if Keyword.get(opts, :ltc, true),
        do: ltc_devices(snapshot, bus_by_id, gen_buses, ltc_band),
        else: []

    caps =
      if Keyword.get(opts, :capacitors, true),
        do: capacitor_capacity(snapshot, bus_by_id, peak, strength),
        else: %{}

    reacs =
      if Keyword.get(opts, :reactors, true),
        do: reactor_capacity(snapshot, bus_by_id, strength),
        else: %{}

    shunts =
      caps
      |> Map.keys()
      |> Kernel.++(Map.keys(reacs))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn bus_id ->
        {cap_step, cap_steps, cap_in} = Map.get(caps, bus_id, {0.0, 0, 0})
        {reac_step, reac_steps, reac_in} = Map.get(reacs, bus_id, {0.0, 0, 0})
        {lo, hi} = shunt_band

        %{
          type: :switched_shunt,
          id: {:shunt, bus_id},
          bus_id: bus_id,
          cap_step_mvar: cap_step,
          cap_steps: cap_steps,
          reac_step_mvar: reac_step,
          reac_steps: reac_steps,
          # Steps the stamped plant already accounts for: the initial position.
          initial: {cap_in, reac_in},
          lo: lo,
          hi: hi
        }
      end)

    ltcs ++ shunts
  end

  defp ltc_devices(snapshot, bus_by_id, gen_buses, {lo, hi}) do
    snapshot.transformers
    |> Enum.filter(&(Map.get(&1, :status, "in_service") == "in_service"))
    |> Enum.flat_map(fn xfmr ->
      from = Map.get(bus_by_id, xfmr.from_bus_id)
      to = Map.get(bus_by_id, xfmr.to_bus_id)
      x = Map.get(xfmr, :x_pu)

      cond do
        is_nil(from) or is_nil(to) ->
          []

        not (is_number(from.base_kv) and is_number(to.base_kv)) ->
          []

        # Not a voltage crossing: a bus tie or a star-point branch, nothing an
        # LTC would sit on. Negative x is a 3-winding star branch.
        from.base_kv == to.base_kv or not (is_number(x) and x > 0.0) ->
          []

        true ->
          controlled = if from.base_kv < to.base_kv, do: from, else: to

          if MapSet.member?(gen_buses, controlled.id) or Map.get(controlled, :bus_type) in [2, 3] do
            []
          else
            [
              %{
                type: :ltc,
                id: {:ltc, xfmr.id},
                transformer_id: xfmr.id,
                controlled_bus_id: controlled.id,
                high_bus_id:
                  if(controlled.id == xfmr.to_bus_id, do: xfmr.from_bus_id, else: xfmr.to_bus_id),
                # V_to ≈ V_from / t. Raising the controlled voltage means
                # LOWERING t when the controlled bus is `to`, raising it when
                # the controlled bus is the tapped `from` side.
                raise_sign: if(controlled.id == xfmr.to_bus_id, do: -1.0, else: 1.0),
                step: @ltc_step,
                t_min: @ltc_min,
                t_max: @ltc_max,
                lo: lo,
                hi: hi
              }
            ]
          end
      end
    end)
  end

  # Bus strength proxy, MVA: self-susceptance (Σ 1/x over in-service branches)
  # times base. An upper bound on the short-circuit strength.
  defp strength_mva(snapshot, base_mva \\ 100.0) do
    branches =
      Enum.filter(snapshot.lines, &(Map.get(&1, :status, "in_service") == "in_service")) ++
        Enum.filter(snapshot.transformers, &(Map.get(&1, :status, "in_service") == "in_service"))

    Enum.reduce(branches, %{}, fn br, acc ->
      x = Map.get(br, :x_pu)

      if is_number(x) and x != 0.0 do
        b = base_mva / abs(x)
        acc |> Map.update(br.from_bus_id, b, &(&1 + b)) |> Map.update(br.to_bus_id, b, &(&1 + b))
      else
        acc
      end
    end)
  end

  defp max_step(strength, bus_id, class_step) do
    case Map.get(strength, bus_id) do
      s when is_number(s) and s > 0.0 -> min(class_step, s * @voltage_step_fraction)
      _ -> class_step
    end
  end

  # %{bus_id => {step_mvar, steps, initial_in}}. Load buses get banks sized to
  # peak load Q; a bus with a capacitor bank already stamped gets that bank as
  # steps that start IN, on top of whatever its load sizes.
  defp capacitor_capacity(snapshot, bus_by_id, peak, strength) do
    load_q =
      Map.get(snapshot, :loads, [])
      |> Enum.filter(&(Map.get(&1, :status, "in_service") == "in_service"))
      |> Enum.group_by(& &1.bus_id)
      |> Map.new(fn {bus_id, loads} ->
        {bus_id, Enum.reduce(loads, 0.0, &(&2 + max(&1.q_mvar || 0.0, 0.0))) * peak}
      end)

    fixed =
      snapshot.buses
      |> Enum.filter(&((Map.get(&1, :bs_mvar) || 0.0) > 0.0))
      |> Map.new(&{&1.id, &1.bs_mvar})

    (Map.keys(load_q) ++ Map.keys(fixed))
    |> Enum.uniq()
    |> Enum.flat_map(fn bus_id ->
      case Map.get(bus_by_id, bus_id) do
        nil ->
          []

        bus ->
          ceiling = ParameterEstimator.cap_class_ceiling(bus.base_kv)
          stamped = Map.get(fixed, bus_id, 0.0)
          capacity = min(Map.get(load_q, bus_id, 0.0), ceiling) + stamped
          step = max_step(strength, bus_id, class_value(@cap_step_mvar, bus.base_kv))

          case steps_for(capacity, step) do
            nil -> []
            {step, n} -> [{bus_id, with_initial(step, n, stamped)}]
          end
      end
    end)
    |> Map.new()
  end

  # Steps the stamped plant occupies. The count is rounded, so the stamped
  # plant is representable, and the total is raised to hold it if need be.
  defp with_initial(step, n, stamped) do
    n0 = if stamped >= @min_bank_mvar, do: max(round(stamped / step), 1), else: 0
    {step, max(n, n0), n0}
  end

  # %{bus_id => {step_mvar, steps, initial_in}}: enough reactor to bring the
  # bus's incident charging to 100 % compensation, with the reactor already
  # stamped there as steps that start IN.
  defp reactor_capacity(snapshot, bus_by_id, strength, base_mva \\ 100.0) do
    snapshot.lines
    |> Enum.filter(&(Map.get(&1, :status, "in_service") == "in_service"))
    |> Enum.reduce(%{}, fn line, acc ->
      half = (Map.get(line, :b_pu) || 0.0) * base_mva / 2.0

      if half > 0.0 do
        acc
        |> Map.update(line.from_bus_id, half, &(&1 + half))
        |> Map.update(line.to_bus_id, half, &(&1 + half))
      else
        acc
      end
    end)
    |> Enum.flat_map(fn {bus_id, charging} ->
      bus = Map.get(bus_by_id, bus_id)

      if bus && is_number(bus.base_kv) && bus.base_kv >= @reactor_min_kv do
        stamped = -min(Map.get(bus, :bs_mvar) || 0.0, 0.0)
        capacity = max(charging, stamped)
        step = max_step(strength, bus_id, class_value(@reactor_step_mvar, bus.base_kv))

        case steps_for(capacity, step) do
          nil -> []
          {step, n} -> [{bus_id, with_initial(step, n, stamped)}]
        end
      else
        []
      end
    end)
    |> Map.new()
  end

  # Discretize a capacity into equal steps no larger than `step` that cover it
  # EXACTLY. Truncating to whole class steps was measured to matter: Western's
  # bus 73810 (500 kV) carries 185 MVAr of incident charging and a stamped
  # −111 MVAr reactor; 185 / 100 truncated to ONE step, which the stamped
  # reactor already occupied, and the 85 MVAr the rule meant to provide was
  # silently dropped — leaving the cluster at 1.127 pu with the loop reporting
  # nothing left to switch. Below one step the installation is a single step
  # of its own size; below the smallest bank that gets built, nothing.
  defp steps_for(capacity, _step) when capacity < @min_bank_mvar, do: nil

  defp steps_for(capacity, step) when capacity <= step, do: {capacity, 1}

  defp steps_for(capacity, step) do
    n = ceil(capacity / step - 1.0e-9)
    {capacity / n, n}
  end

  defp class_value(table, kv) when is_number(kv) and kv > 0.0 do
    closest = table |> Map.keys() |> Enum.min_by(&abs(&1 - kv))
    Map.fetch!(table, closest)
  end

  defp class_value(table, _), do: table |> Map.values() |> Enum.min()

  # ---------------------------------------------------------------------------
  # The control loop
  # ---------------------------------------------------------------------------

  @doc """
  Solve one island with its voltage controls active.

  Options: everything `FDPF.solve/2` takes, plus

    * `:devices` — the device list (default: `devices(snapshot, opts)`)
    * `:control_state` — positions from a previous solve's
      `solution.voltage_control.state`, so devices resume where they were
    * `:max_rounds` — round cap (default #{@max_rounds})
    * `:unconverged_rounds` — rounds a device may act on an unconverged
      iterate (default #{@default_unconverged_rounds}; see the attribute)
    * `:warm` — warm-start each round from the previous one (default true)
    * `:max_ltc_steps_per_round` — default #{@max_ltc_steps_per_round}

  Returns `{:ok, %Solution{}}` with `:voltage_control` set to a summary map:
  rounds run, device counts, MVAr switched in, taps moved, remaining
  violations, why the loop stopped, and the final `:state`.
  """
  def solve(snapshot, opts \\ []) do
    devices = Keyword.get_lazy(opts, :devices, fn -> devices(snapshot, opts) end)
    max_rounds = Keyword.get(opts, :max_rounds, @max_rounds)

    fdpf_opts =
      Keyword.drop(opts, [
        :devices,
        :control_state,
        :max_rounds,
        :peak_multiplier,
        :trace,
        :ltc,
        :capacitors,
        :reactors,
        :ltc_band,
        :shunt_band,
        :unconverged_rounds,
        :warm,
        :max_ltc_steps_per_round
      ])

    state = initial_state(devices, Keyword.get(opts, :control_state), snapshot)

    ctx = %{
      fdpf_opts: fdpf_opts,
      max_rounds: max_rounds,
      trace: Keyword.get(opts, :trace, false),
      unconverged_rounds: Keyword.get(opts, :unconverged_rounds, @default_unconverged_rounds),
      warm: Keyword.get(opts, :warm, true),
      ltc_steps: Keyword.get(opts, :max_ltc_steps_per_round, @max_ltc_steps_per_round)
    }

    loop(snapshot, devices, state, ctx, 0, nil, nil, 0, 0)
  end

  # `prev` is `%{state:, actions:}` — the state the last round started from
  # and what it moved — so a diverged round can be backed off. `unconverged`
  # counts rounds acted on without a converged base; `backoffs` is telemetry.
  defp loop(snapshot, devices, state, ctx, round, last_good, prev, unconverged, backoffs) do
    applied = apply_state(snapshot, devices, state)

    opts =
      if last_good && ctx.warm,
        do: Keyword.put(ctx.fdpf_opts, :warm_start, last_good.sol),
        else: ctx.fdpf_opts

    case run_fdpf(applied, opts) do
      {:ok, %Solution{converged: true} = sol} ->
        advance(snapshot, devices, state, ctx, round, sol, prev, backoffs)

      {:ok, %Solution{} = sol} when prev != nil ->
        trace(ctx.trace, round, sol, [], state)
        back_off(snapshot, devices, state, ctx, round, last_good, prev, backoffs)

      {:ok, %Solution{} = sol}
      when unconverged < ctx.unconverged_rounds and round < ctx.max_rounds ->
        # Act on the last iterate as if it named where the network is failing.
        v = Enum.zip(sol.bus_ids, sol.vm_pu) |> Map.new()
        {actions, state} = decide(devices, state, v, ctx)
        trace(ctx.trace, round, sol, actions, state)

        if actions == [] do
          {:ok, finish(sol, devices, state, round, :diverged, backoffs)}
        else
          state = move(state, actions)
          loop(snapshot, devices, state, ctx, round + 1, nil, nil, unconverged + 1, backoffs)
        end

      {:ok, %Solution{} = sol} ->
        trace(ctx.trace, round, sol, [], state)
        {:ok, finish(sol, devices, state, round, :diverged, backoffs)}

      {:error, reason} when prev != nil ->
        Logger.debug(
          "voltage-control round #{round}: solver refused (#{inspect(reason)}); backing off"
        )

        back_off(snapshot, devices, state, ctx, round, last_good, prev, backoffs)

      {:error, reason} ->
        throw({:error, reason})
    end
  end

  # A converged operating point. First undo any move of the last round that
  # carried its bus across the band (rule 6) — those devices are latched at
  # their previous position and the corrected state is solved again before
  # anything else decides on it. Then decide, move, go again.
  defp advance(snapshot, devices, state, ctx, round, sol, prev, backoffs) do
    v = Enum.zip(sol.bus_ids, sol.vm_pu) |> Map.new()

    case crossed(devices, prev, v) do
      [] ->
        {actions, state} = decide(devices, state, v, ctx)
        trace(ctx.trace, round, sol, actions, state)

        cond do
          actions == [] ->
            {:ok, finish(sol, devices, state, round, :settled, backoffs)}

          round >= ctx.max_rounds ->
            {:ok, finish(sol, devices, state, round, :round_cap, backoffs)}

          true ->
            prev = %{state: state, actions: actions, v: v}
            good = %{sol: sol, state: state}
            state = move(state, actions)
            loop(snapshot, devices, state, ctx, round + 1, good, prev, 0, backoffs)
        end

      overshot ->
        trace_overshoot(ctx.trace, round, overshot)
        ids = MapSet.new(overshot, &elem(&1, 0))

        state =
          Enum.reduce(ids, state, fn id, st ->
            before = Map.fetch!(prev.state.positions, id)
            k = Map.get(st.split, id, 1)

            case id do
              {:shunt, _} when k < @max_split_factor ->
                # Rule 10: halve the step, re-express the position, try again.
                {c, r} = before

                %{
                  st
                  | positions: Map.put(st.positions, id, {c * 2, r * 2}),
                    split: Map.put(st.split, id, k * 2)
                }

              _ ->
                %{
                  st
                  | positions: Map.put(st.positions, id, before),
                    latched: MapSet.put(st.latched, id)
                }
            end
          end)

        kept = Enum.reject(prev.actions, fn {id, _, _} -> MapSet.member?(ids, id) end)
        good = %{sol: sol, state: %{prev.state | latched: state.latched}}
        prev = if kept == [], do: nil, else: %{prev | actions: kept}
        loop(snapshot, devices, state, ctx, round + 1, good, prev, 0, backoffs + 1)
    end
  end

  # Actions of the last round whose bus ended on the far side of its band.
  defp crossed(_devices, nil, _v), do: []

  defp crossed(devices, %{actions: actions, v: v_before}, v_after) do
    by_id = Map.new(devices, &{&1.id, &1})

    Enum.filter(actions, fn {id, _dir, _pos} ->
      d = Map.fetch!(by_id, id)
      bus = if d.type == :ltc, do: d.controlled_bus_id, else: d.bus_id

      case {side(Map.get(v_before, bus), d), side(Map.get(v_after, bus), d)} do
        {:below, :above} -> true
        {:above, :below} -> true
        _ -> false
      end
    end)
  end

  defp side(nil, _d), do: :in
  defp side(v, %{lo: lo}) when v < lo, do: :below
  defp side(v, %{hi: hi}) when v > hi, do: :above
  defp side(_v, _d), do: :in

  # The round's moves broke the solve. Revert them from the state the round
  # started at. If shunts and taps both moved, the shunts are the suspects:
  # latch them and let the taps try alone. If it was already taps alone (or
  # shunts alone), latch everything that moved. Either way the loop resumes
  # from the last converged point — whose solution is already in hand, so no
  # solve is spent re-deriving it.
  defp back_off(snapshot, devices, state, ctx, round, last_good, prev, backoffs) do
    {shunt_acts, ltc_acts} = Enum.split_with(prev.actions, fn {{k, _}, _, _} -> k == :shunt end)
    {supply, absorb} = Enum.split_with(shunt_acts, fn {_, dir, _} -> dir == :raise end)

    # {moves to retry, moves to revert}; nil retry means a full revert.
    {retry, revert} =
      cond do
        shunt_acts != [] and ltc_acts != [] -> {ltc_acts, shunt_acts}
        supply != [] and absorb != [] -> {absorb, supply}
        true -> {nil, prev.actions}
      end

    penalized = penalize(prev.state, revert)
    trace_backoff(ctx.trace, round, prev.actions, retry)

    cond do
      round >= ctx.max_rounds ->
        {:ok, finish(last_good.sol, devices, penalized, round, :round_cap, backoffs + 1)}

      retry != nil ->
        retry_state = move(penalized, retry)
        retry_prev = %{prev | state: penalized, actions: retry}

        loop(
          snapshot,
          devices,
          retry_state,
          ctx,
          round + 1,
          last_good,
          retry_prev,
          0,
          backoffs + 1
        )

      true ->
        # Full revert: the last converged solution is the current operating
        # point again. Re-decide on it with the offenders penalized.
        _ = state
        advance(snapshot, devices, penalized, ctx, round + 1, last_good.sol, nil, backoffs + 1)
    end
  end

  # Offenders of a diverged round, at the positions the round started from: a
  # shunt has its step halved (or is latched once it cannot be halved), a tap
  # is latched.
  defp penalize(state, actions) do
    Enum.reduce(actions, state, fn {id, _dir, _pos}, st ->
      before = Map.fetch!(st.positions, id)
      k = Map.get(st.split, id, 1)

      case id do
        {:shunt, _} when k < @max_split_factor ->
          {c, r} = before

          %{
            st
            | positions: Map.put(st.positions, id, {c * 2, r * 2}),
              split: Map.put(st.split, id, k * 2)
          }

        _ ->
          %{st | latched: MapSet.put(st.latched, id)}
      end
    end)
  end

  defp trace_overshoot(false, _round, _overshot), do: :ok

  defp trace_overshoot(true, round, overshot) do
    Logger.info(
      "voltage-control round #{round}: #{length(overshot)} move(s) carried their bus across " <>
        "the band — reverted and latched"
    )
  end

  defp trace_backoff(false, _round, _actions, _retry), do: :ok

  defp trace_backoff(true, round, actions, retry) do
    n = length(actions)

    how =
      case retry do
        nil -> "reverting all #{n}"
        kept -> "reverting #{n - length(kept)}, retrying #{length(kept)} alone"
      end

    Logger.info("voltage-control round #{round}: diverged after #{n} moves — #{how}")
  end

  defp trace(false, _round, _sol, _actions, _state), do: :ok

  defp trace(true, round, sol, actions, state) do
    {ltc, shunt} = Enum.split_with(actions, fn {{kind, _}, _, _} -> kind == :ltc end)
    dirs = fn acts -> Enum.frequencies_by(acts, &elem(&1, 1)) end

    Logger.info(
      "voltage-control round #{round}: converged=#{sol.converged} iters=#{sol.iterations} " <>
        "mismatch=#{inspect(sol.max_mismatch)} Vm #{Float.round(Enum.min(sol.vm_pu), 4)}.." <>
        "#{Float.round(Enum.max(sol.vm_pu), 4)} | ltc moves #{inspect(dirs.(ltc))} " <>
        "shunt moves #{inspect(dirs.(shunt))} latched #{MapSet.size(state.latched)}"
    )
  end

  defp run_fdpf(snapshot, opts) do
    FDPF.solve(snapshot, opts)
  catch
    :throw, {:error, reason} -> {:error, reason}
  end

  # ---------------------------------------------------------------------------
  # State
  #
  # %{positions: %{device_id => pos}, moves: %{device_id => {last_dir, reversals}},
  #   latched: MapSet}
  # pos is {caps_in, reacs_in} for a shunt and the tap ratio for an LTC.
  # ---------------------------------------------------------------------------

  defp initial_state(devices, nil, snapshot) do
    taps = Map.new(snapshot.transformers, &{&1.id, tap_of(&1)})

    positions =
      Map.new(devices, fn
        %{type: :ltc} = d -> {d.id, Map.get(taps, d.transformer_id, 1.0)}
        %{type: :switched_shunt} = d -> {d.id, Map.get(d, :initial, {0, 0})}
      end)

    %{positions: positions, moves: %{}, latched: MapSet.new(), split: %{}}
  end

  defp initial_state(devices, %{positions: prev} = carried, snapshot) do
    fresh = initial_state(devices, nil, snapshot)
    # Resume any device the carried state knows; new devices start fresh.
    positions = Map.merge(fresh.positions, Map.take(prev, Map.keys(fresh.positions)))
    split = Map.take(Map.get(carried, :split, %{}), Map.keys(fresh.positions))
    %{fresh | positions: positions, split: split}
  end

  # A shunt device as the state currently sees it: its step divided by the
  # splits it has suffered, counts and initial position scaled to match.
  defp effective(%{type: :switched_shunt} = d, state) do
    k = Map.get(state.split, d.id, 1)
    {caps0, reacs0} = Map.get(d, :initial, {0, 0})

    %{
      cap_step: d.cap_step_mvar / k,
      cap_steps: d.cap_steps * k,
      reac_step: d.reac_step_mvar / k,
      reac_steps: d.reac_steps * k,
      initial: {caps0 * k, reacs0 * k}
    }
  end

  defp tap_of(xfmr) do
    case Map.get(xfmr, :tap_ratio) do
      t when is_number(t) and t > 0.0 -> t
      _ -> 1.0
    end
  end

  defp apply_state(snapshot, devices, state) do
    shunt_mvar =
      devices
      |> Enum.filter(&(&1.type == :switched_shunt))
      |> Enum.reduce(%{}, fn d, acc ->
        {caps, reacs} = Map.fetch!(state.positions, d.id)
        e = effective(d, state)
        {caps0, reacs0} = e.initial
        mvar = (caps - caps0) * e.cap_step - (reacs - reacs0) * e.reac_step
        if mvar == 0.0, do: acc, else: Map.update(acc, d.bus_id, mvar, &(&1 + mvar))
      end)

    taps =
      devices
      |> Enum.filter(&(&1.type == :ltc))
      |> Map.new(&{&1.transformer_id, Map.fetch!(state.positions, &1.id)})

    buses =
      if map_size(shunt_mvar) == 0 do
        snapshot.buses
      else
        Enum.map(snapshot.buses, fn bus ->
          case Map.get(shunt_mvar, bus.id) do
            nil -> bus
            mvar -> Map.put(bus, :bs_mvar, (Map.get(bus, :bs_mvar) || 0.0) + mvar)
          end
        end)
      end

    transformers =
      if map_size(taps) == 0 do
        snapshot.transformers
      else
        Enum.map(snapshot.transformers, fn xfmr ->
          case Map.get(taps, xfmr.id) do
            nil -> xfmr
            t -> Map.put(xfmr, :tap_ratio, t)
          end
        end)
      end

    %{snapshot | buses: buses, transformers: transformers}
  end

  # ---------------------------------------------------------------------------
  # Decisions
  # ---------------------------------------------------------------------------

  # Returns {actions, state}. An action is {device_id, direction, new_position}.
  # `state` comes back with newly latched devices recorded. Shunts decide
  # first; taps act only in a round where no shunt wants to move.
  defp decide(devices, state, v, ctx) when is_map(v) do
    {shunt_actions, state} =
      devices
      |> Enum.filter(&(&1.type == :switched_shunt))
      |> Enum.reduce({[], state}, fn d, {acts, st} ->
        case shunt_action(d, st, Map.get(v, d.bus_id)) do
          {:move, dir, pos} -> {[{d.id, dir, pos} | acts], st}
          {:latch, st} -> {acts, st}
          :hold -> {acts, st}
        end
      end)

    if shunt_actions != [] do
      {shunt_actions, state}
    else
      {wanting, state} =
        devices
        |> Enum.filter(&(&1.type == :ltc))
        |> Enum.reduce({[], state}, fn d, {acts, st} ->
          v_high =
            case Map.get(d, :high_bus_id) do
              nil -> nil
              high -> Map.get(v, high)
            end

          case ltc_action(d, st, Map.get(v, d.controlled_bus_id), v_high, ctx.ltc_steps) do
            {:move, dir, pos} -> {[{d, dir, pos} | acts], st}
            {:latch, st} -> {acts, st}
            :hold -> {acts, st}
          end
        end)

      # Upstream first (rule 7): a tap whose high side is itself the
      # controlled bus of a tap that wants to move waits for it.
      moving_low_sides = MapSet.new(wanting, fn {d, _, _} -> d.controlled_bus_id end)

      actions =
        wanting
        |> Enum.reject(fn {d, _, _} ->
          case Map.get(d, :high_bus_id) do
            nil -> false
            high -> MapSet.member?(moving_low_sides, high)
          end
        end)
        |> Enum.map(fn {d, dir, pos} -> {d.id, dir, pos} end)

      {actions, state}
    end
  end

  defp ltc_action(_d, _state, nil, _v_high, _max_steps), do: :hold

  defp ltc_action(d, state, v, v_high, max_steps) do
    want = wanted(v, d.lo, d.hi)

    cond do
      want == :hold ->
        :hold

      MapSet.member?(state.latched, d.id) ->
        :hold

      # Rule 9: no raising into a transmission side that is already low.
      want == :raise and is_number(v_high) and v_high < @ltc_block_below ->
        :hold

      # Rule 10: no lowering under a transmission side that is already high.
      want == :lower and is_number(v_high) and v_high > @ltc_block_above ->
        :hold

      true ->
        t = Map.fetch!(state.positions, d.id)
        centre = (d.lo + d.hi) / 2.0
        steps = min(max(round(abs(centre - v) / d.step), 1), max_steps)
        sign = if want == :raise, do: d.raise_sign, else: -d.raise_sign
        target = t + sign * steps * d.step
        clamped = target |> min(d.t_max) |> max(d.t_min)

        if abs(clamped - t) < d.step / 2.0 do
          # Already at the limit in the wanted direction: exhausted.
          :hold
        else
          reversal_or_move(d.id, state, want, clamped)
        end
    end
  end

  defp shunt_action(_d, _state, nil), do: :hold

  defp shunt_action(d, state, v) do
    want = wanted(v, d.lo, d.hi)

    cond do
      want == :hold ->
        :hold

      MapSet.member?(state.latched, d.id) ->
        :hold

      true ->
        {caps, reacs} = Map.fetch!(state.positions, d.id)
        e = effective(d, state)

        next =
          case want do
            :lower ->
              cond do
                caps > 0 -> {caps - 1, reacs}
                reacs < e.reac_steps -> {caps, reacs + 1}
                true -> nil
              end

            :raise ->
              cond do
                reacs > 0 -> {caps, reacs - 1}
                caps < e.cap_steps -> {caps + 1, reacs}
                true -> nil
              end
          end

        case next do
          nil -> :hold
          pos -> reversal_or_move(d.id, state, want, pos)
        end
    end
  end

  defp wanted(v, lo, _hi) when v < lo, do: :raise
  defp wanted(v, _lo, hi) when v > hi, do: :lower
  defp wanted(_v, _lo, _hi), do: :hold

  # The anti-hunting latch: a device may reverse @max_reversals times, then it
  # stays where it is.
  defp reversal_or_move(id, state, dir, pos) do
    case Map.get(state.moves, id) do
      {last, reversals} when last != dir and reversals >= @max_reversals ->
        {:latch, %{state | latched: MapSet.put(state.latched, id)}}

      _ ->
        {:move, dir, pos}
    end
  end

  defp move(state, actions) do
    Enum.reduce(actions, state, fn {id, dir, pos}, st ->
      moves =
        Map.update(st.moves, id, {dir, 0}, fn
          {^dir, r} -> {dir, r}
          {_other, r} -> {dir, r + 1}
        end)

      %{st | positions: Map.put(st.positions, id, pos), moves: moves}
    end)
  end

  # ---------------------------------------------------------------------------
  # Reporting
  # ---------------------------------------------------------------------------

  defp finish(%Solution{} = sol, devices, state, rounds, stopped, backoffs) do
    v = Enum.zip(sol.bus_ids, sol.vm_pu) |> Map.new()
    ltcs = Enum.filter(devices, &(&1.type == :ltc))
    shunts = Enum.filter(devices, &(&1.type == :switched_shunt))

    # MVAr switched relative to the stamped plant: positive = added, negative
    # = stamped plant switched out.
    {cap_in, reac_in, shunt_moved} =
      Enum.reduce(shunts, {0.0, 0.0, 0}, fn d, {c, r, m} ->
        {caps, reacs} = Map.fetch!(state.positions, d.id)
        e = effective(d, state)
        {caps0, reacs0} = e.initial
        moved = if Map.has_key?(state.moves, d.id), do: 1, else: 0
        {c + (caps - caps0) * e.cap_step, r + (reacs - reacs0) * e.reac_step, m + moved}
      end)

    {ltc_moved, ltc_at_limit} =
      Enum.reduce(ltcs, {0, 0}, fn d, {m, l} ->
        t = Map.fetch!(state.positions, d.id)
        moved = if Map.has_key?(state.moves, d.id), do: 1, else: 0
        at_limit = if t <= d.t_min + 1.0e-9 or t >= d.t_max - 1.0e-9, do: 1, else: 0
        {m + moved, l + at_limit}
      end)

    violations =
      Enum.reduce(ltcs ++ shunts, %{lo: 0, hi: 0}, fn d, acc ->
        bus = if d.type == :ltc, do: d.controlled_bus_id, else: d.bus_id

        case Map.get(v, bus) do
          nil -> acc
          vv when vv < d.lo -> %{acc | lo: acc.lo + 1}
          vv when vv > d.hi -> %{acc | hi: acc.hi + 1}
          _ -> acc
        end
      end)

    summary = %{
      rounds: rounds,
      stopped: stopped,
      backoffs: backoffs,
      devices: length(devices),
      ltc: %{
        count: length(ltcs),
        moved: ltc_moved,
        at_limit: ltc_at_limit,
        latched: Enum.count(ltcs, &MapSet.member?(state.latched, &1.id))
      },
      shunt: %{
        count: length(shunts),
        moved: shunt_moved,
        cap_mvar_in: Float.round(cap_in, 1),
        reac_mvar_in: Float.round(reac_in, 1),
        latched: Enum.count(shunts, &MapSet.member?(state.latched, &1.id)),
        split: map_size(state.split)
      },
      controlled_bus_violations: violations,
      state: state
    }

    %{sol | voltage_control: summary}
  end
end
