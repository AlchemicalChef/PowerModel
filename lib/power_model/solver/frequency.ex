defmodule PowerModel.Solver.Frequency do
  @moduledoc """
  Frequency dynamics simulation using the swing equation with governor response.

  Models the system frequency response after a power imbalance event (e.g.,
  generator trip or sudden load change) by integrating:

      d(df)/dt = (P_mech - P_elec) / (2 * H_sys * S_sys)

  Key components:
  - **System inertia (H)**: Weighted average of generator inertia constants.
    Determines the initial rate of frequency decline. Wind/solar/storage
    (inverter-based) contribute zero inertia.
  - **Governor droop**: Generators increase mechanical output proportional to
    frequency drop, with a first-order time delay (governor time constant).
  - **Load damping**: Loads naturally reduce ~D% per 1% frequency drop
    (D coefficient, typically ~1.0). Damping acts on the load that is still
    connected (baseline minus cumulative UFLS shed).
  - **UFLS**: Under-Frequency Load Shedding at staged thresholds with time
    delays to prevent nuisance tripping. Each stage sheds a fraction of the
    CURRENTLY-CONNECTED load, not the pre-event total.

  Numerical stability: the explicit-Euler step is proven stable iff
  `beta = dt * D * Pload / (2 * H_sys * S_sys) < 2` (see
  `proofs/Proofs/Swing.lean`, theorem `beta_lt_two_iff`). `simulate/5`
  computes `beta` per simulation and shrinks `dt` so that `beta <= 1`.
  """

  require Logger

  # Nominal frequency (Hz)
  @f0 60.0

  # Default inertia constants by fuel type (seconds)
  @default_inertia %{
    "nuclear" => 6.0,
    "coal" => 4.0,
    # oil-fired steam units: steam-turbine-like rotor
    "oil" => 4.0,
    "gas" => 3.5,
    # geothermal: small steam turbines
    "geothermal" => 3.5,
    "hydro" => 3.0,
    # inverter-based, no synchronous rotor
    "storage" => 0.0,
    "wind" => 0.0,
    "solar" => 0.0,
    "import" => 0.0
  }

  # Governor time constants by prime mover / fuel type (seconds)
  @default_gov_time %{
    # steam turbine, slow
    "nuclear" => 5.0,
    # steam turbine, slow
    "coal" => 5.0,
    # oil-fired steam turbine, slow
    "oil" => 5.0,
    # gas turbine, fast
    "gas" => 0.5,
    # geothermal steam turbine, slow
    "geothermal" => 5.0,
    # hydro governor
    "hydro" => 2.0,
    # no governor response (inverter-based storage)
    "storage" => 999.0,
    # no governor response
    "wind" => 999.0,
    # no governor response
    "solar" => 999.0,
    # tie-line imports have no local governor response
    "import" => 999.0
  }

  # EIA-860/923 energy source codes as stored on generators (PLT-3).
  # Checked BEFORE the substring heuristics so that e.g. "SUB" (subbituminous
  # coal) does not fall through to the "gas" default. MWH (batteries) maps to
  # storage: zero inertia and no governor.
  @eia_fuel_codes %{
    "SUB" => "coal",
    "LIG" => "coal",
    "RC" => "coal",
    "WC" => "coal",
    "BIT" => "coal",
    "MWH" => "storage",
    "DFO" => "oil",
    "RFO" => "oil",
    "GEO" => "geothermal",
    "NUC" => "nuclear",
    "NG" => "gas",
    "WAT" => "hydro",
    "WND" => "wind",
    "SUN" => "solar"
  }

  # Droop coefficient (5% means 5% frequency deviation -> 100% power change)
  @droop 0.05

  # Load damping coefficient (D = 1.0 means 1% load reduction per 1% freq drop)
  @load_damping 1.0

  # Physical clamp band for the simulated frequency (Hz)
  @f_min 55.0
  @f_max 65.0

  # Sane upper bound on the number of Euler steps a single simulation may take
  # after the stability-driven dt shrink (ENE-5).
  @max_total_steps 10_000

  # UFLS stages: {threshold_hz, shed_fraction, arming_delay_s}
  # NERC PRC-006-style regional program: staged shedding beginning at 59.3 Hz,
  # each stage shedding a further 7.5% of the currently-connected load —
  # ~30% cumulative by 58.1 Hz.
  @ufls_stages [
    {59.3, 0.075, 0.1},
    {58.9, 0.075, 0.1},
    {58.5, 0.075, 0.1},
    {58.1, 0.075, 0.1}
  ]

  @doc """
  The canonical UFLS program: `{threshold_hz, shed_fraction, arming_delay_s}`
  per stage, shed fractions incremental. Single source of truth — the static
  nadir-based schedule in `PowerModel.Failure.Protection.ufls_schedule/1`
  derives its cumulative fractions from this table.
  """
  def ufls_stages, do: @ufls_stages

  @doc """
  Load damping coefficient D (fractional load change per fractional frequency
  deviation). Exposed so the static steady-state frequency estimate in
  `PowerModel.Failure.Protection.estimate_frequency/3` stays consistent with
  the dynamic model.
  """
  def load_damping, do: @load_damping

  @doc """
  Simulate the system frequency response after a power imbalance event.

  ## Parameters

  - `generators` - list of generator maps (must have :p_max_mw, :capacity_factor;
    optionally :fuel_type for inertia/governor lookup)
  - `loads` - list of load maps (must have :p_mw)
  - `lost_mw` - MW of generation lost (positive) or load lost (negative)
  - `dt_seconds` - requested simulation time step (default 0.1s). May be
    shrunk internally to keep the Euler step numerically stable (see below).
  - `duration_seconds` - total simulation duration (default 30.0s)

  ## Returns

  A list of time-step maps:
      %{
        time: float(),          # seconds
        frequency: float(),     # Hz
        gov_response_mw: float(), # total governor MW pickup
        load_shed_mw: float(),  # cumulative UFLS shed MW
        collapsed: boolean()    # true once the frequency has hit the
                                # physical clamp (55/65 Hz) — the trajectory
                                # from that point on is saturated, not a
                                # resolved swing solution
      }

  `collapsed` is sticky: once any step touches the clamp every later record
  carries `collapsed: true`, so `collapsed?/1` can read the last record.

  ## Numerical stability (ENE-5)

  The explicit-Euler swing step contracts toward its equilibrium iff
  `beta = dt * D * Pload / (2 * H_sys * S_sys) < 2` — equivalently
  `dt < 4*H*S / (D * Pload)` — see `proofs/Proofs/Swing.lean`, theorem
  `beta_lt_two_iff` (and `stepDf_contracts`). We compute `beta` for each
  simulation and shrink `dt` so that `beta <= 1` (a comfortable margin below
  the proven bound), capping the total number of steps at #{@max_total_steps}.
  """
  @spec simulate(list(map()), list(map()), float(), float(), float()) :: list(map())
  def simulate(generators, loads, lost_mw, dt_seconds \\ 0.1, duration_seconds \\ 30.0) do
    # Compute system parameters
    online_gens =
      Enum.filter(generators, fn g ->
        (Map.get(g, :capacity_factor) || 1.0) > 0.0 and (Map.get(g, :p_max_mw) || 0.0) > 0.0
      end)

    {h_sys, s_sys} = system_inertia(online_gens)
    total_load_mw = Enum.sum(Enum.map(loads, & &1.p_mw))

    # ENE-4: floor the kinetic-energy PRODUCT 2*H*S (MW·s), not the H
    # constant. Flooring H alone created a 34x discontinuity in 2HS when a
    # small fleet change crossed the old `h_sys < 0.01` threshold. The floor
    # is a minimum kinetic-energy proxy of 1 MW·s per MW of load (H_equiv =
    # 0.5 s on the load base), so a zero-inertia (all-inverter) island still
    # integrates without dividing by zero and neighboring fleets get
    # neighboring dynamics.
    two_h_s = max(2.0 * h_sys * s_sys, 1.0 * max(total_load_mw, 1.0))

    # ENE-5: enforce the proven Euler stability bound. The step contracts iff
    # beta = dt*D*Pload/(2HS) < 2 (proofs/Proofs/Swing.lean, beta_lt_two_iff);
    # we shrink dt so beta <= 1. Pload only decreases as UFLS sheds, so the
    # initial beta is the worst case.
    beta = dt_seconds * @load_damping * total_load_mw / two_h_s
    dt = if beta > 1.0, do: dt_seconds / beta, else: dt_seconds

    raw_steps = round(duration_seconds / dt)

    {dt, total_steps} =
      if raw_steps > @max_total_steps do
        {duration_seconds / @max_total_steps, @max_total_steps}
      else
        {dt, raw_steps}
      end

    # Build governor model for each generator
    gov_units = build_governor_units(online_gens)

    initial_record = %{
      time: 0.0,
      frequency: @f0,
      gov_response_mw: 0.0,
      load_shed_mw: 0.0,
      collapsed: false
    }

    # ENE-11/SOL-7: duration shorter than one step — return just the initial
    # record instead of iterating a descending range.
    if total_steps <= 0 do
      [initial_record]
    else
      # Governor state: each unit tracks its current mechanical power adjustment
      gov_state = Enum.map(gov_units, fn _unit -> 0.0 end)

      # UFLS state: track which stages have been armed and tripped
      ufls_state = Enum.map(@ufls_stages, fn _ -> %{armed_at: nil, tripped: false} end)

      {trajectory, _} =
        Enum.reduce(
          1..total_steps//1,
          {[initial_record],
           %{
             freq: @f0,
             df: 0.0,
             gov_state: gov_state,
             ufls_state: ufls_state,
             cumulative_shed_mw: 0.0,
             total_load_mw: total_load_mw,
             collapsed: false
           }},
          fn step, {records, state} ->
            t = step * dt

            # 1. Governor response: each unit ramps up based on droop and time constant
            {new_gov_state, total_gov_mw} =
              update_governors(gov_units, state.gov_state, state.df, dt)

            # 2. UFLS check — each stage sheds a fraction of the load still
            # connected (ENE-6), not of the pre-event total.
            connected_mw = state.total_load_mw - state.cumulative_shed_mw

            {new_ufls_state, new_shed_mw} =
              update_ufls(state.ufls_state, state.freq, t, connected_mw)

            cumulative_shed = state.cumulative_shed_mw + new_shed_mw
            remaining_load_mw = state.total_load_mw - cumulative_shed

            # 3. Compute power balance
            # P_mech = (total generation - lost_mw) + governor pickup
            # P_elec = remaining load + frequency damping on the remaining load
            p_mech = total_gov_mw

            # Load damping acts on the load still connected (ENE-6):
            # P_load_actual = (P_load - shed) * (1 + D * df/f0)
            load_damping_mw = remaining_load_mw * @load_damping * state.df / @f0

            # Net imbalance: positive means generation > load (frequency rises)
            # lost_mw is subtracted from generation; gov pickup adds to it;
            # UFLS shedding subtracts from the electrical load.
            p_imbalance = -lost_mw + p_mech - load_damping_mw + cumulative_shed

            # 4. Swing equation: df/dt = f0 * P_imbalance / (2 * H_sys * S_sys)
            # Using MW and seconds; two_h_s is the (floored) product 2*H*S.
            dfdt = @f0 * p_imbalance / two_h_s

            # 5. Euler integration
            new_df = state.df + dfdt * dt
            new_freq_raw = @f0 + new_df

            # Clamp frequency to physical bounds; a touched clamp marks the
            # trajectory as collapsed (saturated, not a resolved solution).
            new_freq = new_freq_raw |> max(@f_min) |> min(@f_max)
            new_df = new_freq - @f0
            collapsed = state.collapsed or new_freq_raw < @f_min or new_freq_raw > @f_max

            record = %{
              time: Float.round(t, 4),
              frequency: Float.round(new_freq, 6),
              gov_response_mw: Float.round(total_gov_mw, 2),
              load_shed_mw: Float.round(cumulative_shed, 2),
              collapsed: collapsed
            }

            {[record | records],
             %{
               freq: new_freq,
               df: new_df,
               gov_state: new_gov_state,
               ufls_state: new_ufls_state,
               cumulative_shed_mw: cumulative_shed,
               total_load_mw: state.total_load_mw,
               collapsed: collapsed
             }}
          end
        )

      Enum.reverse(trajectory)
    end
  end

  @doc """
  Return the frequency nadir (minimum frequency) from a simulation trajectory.
  """
  @spec nadir(list(map())) :: float()
  def nadir(trajectory) do
    trajectory
    |> Enum.min_by(& &1.frequency)
    |> Map.get(:frequency)
  end

  @doc """
  Return the settling frequency (final value) from a simulation trajectory.
  """
  @spec settling_frequency(list(map())) :: float()
  def settling_frequency(trajectory) do
    trajectory
    |> List.last()
    |> Map.get(:frequency)
  end

  @doc """
  Whether the trajectory touched the physical frequency clamp (55/65 Hz) at
  any point — i.e. the island's frequency collapsed (or ran away) beyond what
  the linearized swing model can resolve. Callers should treat nadir/settling
  values from a collapsed trajectory as saturated bounds, not solutions.
  """
  @spec collapsed?(list(map())) :: boolean()
  def collapsed?(trajectory) do
    trajectory
    |> List.last()
    |> Map.get(:collapsed, false)
  end

  @doc """
  Compute the system-wide inertia constant H_sys and total MVA base S_sys.

      H_sys = sum(H_i * S_i) / sum(S_i)

  where H_i is the inertia constant and S_i is the MVA rating (approximated
  as p_max_mw for each generator).
  """
  @spec system_inertia(list(map())) :: {float(), float()}
  def system_inertia(generators) do
    {weighted_sum, total_s} =
      Enum.reduce(generators, {0.0, 0.0}, fn gen, {ws, ts} ->
        h = inertia_for(gen)
        # Inertia rides on the machine MVA base (≈ nameplate MW), not the
        # currently dispatched output — a half-loaded machine spins with its
        # full rotor.
        s = nameplate_mw(gen)
        {ws + h * s, ts + s}
      end)

    if total_s > 0.0 do
      {weighted_sum / total_s, total_s}
    else
      {0.0, 0.0}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp inertia_for(gen) do
    fuel = normalize_fuel(Map.get(gen, :fuel_type))
    Map.get(@default_inertia, fuel, 3.5)
  end

  defp gov_time_for(gen) do
    fuel = normalize_fuel(Map.get(gen, :fuel_type))
    Map.get(@default_gov_time, fuel, 2.0)
  end

  defp normalize_fuel(nil), do: "gas"

  defp normalize_fuel(fuel) when is_binary(fuel) do
    # PLT-3: exact EIA energy-source codes first, then substring heuristics
    # for free-text fuel descriptions.
    case Map.get(@eia_fuel_codes, fuel |> String.trim() |> String.upcase()) do
      nil -> heuristic_fuel(fuel)
      canonical -> canonical
    end
  end

  defp heuristic_fuel(fuel) do
    f = String.downcase(fuel)

    cond do
      String.contains?(f, "nuclear") or String.contains?(f, "nuc") ->
        "nuclear"

      String.contains?(f, "coal") or String.contains?(f, "bit") ->
        "coal"

      String.contains?(f, "import") ->
        "import"

      String.contains?(f, "gas") or String.contains?(f, "ng") or String.contains?(f, "ct") ->
        "gas"

      String.contains?(f, "hydro") or String.contains?(f, "wat") ->
        "hydro"

      String.contains?(f, "wind") or String.contains?(f, "wnd") ->
        "wind"

      String.contains?(f, "solar") or String.contains?(f, "sun") or String.contains?(f, "pv") ->
        "solar"

      true ->
        Logger.debug("Frequency: unrecognized fuel type #{inspect(fuel)} -- using gas dynamics")
        "gas"
    end
  end

  # Real dispatch and nameplate capability. The cascade reshapes generators
  # for the DC solver (p_max_mw = dispatched MW, capacity_factor = 1.0), which
  # read naively would zero the governor headroom and shrink the inertia base
  # to the dispatched MW; it attaches the physical values as :p_dispatch_mw /
  # :p_nameplate_mw so the frequency dynamics stay physical.
  defp dispatch_mw(gen) do
    Map.get(gen, :p_dispatch_mw) ||
      gen.p_max_mw * (Map.get(gen, :capacity_factor) || 1.0)
  end

  defp nameplate_mw(gen) do
    Map.get(gen, :p_nameplate_mw) || gen.p_max_mw
  end

  defp build_governor_units(generators) do
    Enum.map(generators, fn gen ->
      p_dispatch = dispatch_mw(gen)
      p_nameplate = nameplate_mw(gen)
      t_gov = gov_time_for(gen)
      h = inertia_for(gen)

      # Governor headroom: how much more the generator can ramp up from its
      # current operating point toward nameplate capability
      headroom = p_nameplate - p_dispatch

      %{
        # Droop responds on the machine base (nameplate), not current output
        p_rated: p_nameplate,
        p_max: p_nameplate,
        p_dispatch: p_dispatch,
        headroom: max(headroom, 0.0),
        t_gov: t_gov,
        droop: @droop,
        has_governor: h > 0.0 and t_gov < 100.0
      }
    end)
  end

  defp update_governors(gov_units, gov_state, df, dt) do
    {new_states, total} =
      Enum.zip(gov_units, gov_state)
      |> Enum.map_reduce(0.0, fn {unit, current_dp}, total_mw ->
        if not unit.has_governor do
          {current_dp, total_mw + current_dp}
        else
          # Desired governor response based on droop
          # dp_target = -(df / f0) / R * P_rated
          # Negative df (underfrequency) -> positive dp (more generation)
          dp_target = -(df / @f0) / unit.droop * unit.p_rated

          # Clamp upward response to headroom and backing down to dispatched output
          dp_target = max(-unit.p_dispatch, min(dp_target, unit.headroom))

          # First-order lag: dp approaches dp_target with time constant T_gov
          # dp_new = dp_old + (dp_target - dp_old) * dt / T_gov
          dp_new = current_dp + (dp_target - current_dp) * min(dt / unit.t_gov, 1.0)

          {dp_new, total_mw + dp_new}
        end
      end)

    {new_states, total}
  end

  # Tolerance for the arming-delay comparison: `time` values are multiples of
  # a binary-inexact dt, so `0.5 - 0.4 < 0.1` in floats — without the epsilon
  # a stage armed for exactly `delay` seconds would wait one extra step.
  @delay_epsilon 1.0e-9

  # `connected_mw` is the load still connected when the step begins; each
  # tripping stage sheds `shed_frac` of the load remaining after the stages
  # that tripped before it — including earlier stages in this same step
  # (ENE-6: fraction of CURRENTLY-connected load, never of the pre-event
  # total).
  defp update_ufls(ufls_state, freq, time, connected_mw) do
    {new_state, total_new_shed} =
      Enum.zip(@ufls_stages, ufls_state)
      |> Enum.map_reduce(0.0, fn {{threshold, shed_frac, delay}, stage_state}, shed_acc ->
        cond do
          stage_state.tripped ->
            # Already tripped, no new shedding
            {stage_state, shed_acc}

          freq < threshold ->
            case stage_state.armed_at do
              nil ->
                # Arm the stage
                {%{stage_state | armed_at: time}, shed_acc}

              armed_time when time - armed_time >= delay - @delay_epsilon ->
                # Delay elapsed, trip the stage
                shed_mw = max(connected_mw - shed_acc, 0.0) * shed_frac
                {%{stage_state | tripped: true}, shed_acc + shed_mw}

              _armed_time ->
                # Still waiting for delay
                {stage_state, shed_acc}
            end

          true ->
            # Frequency above threshold, reset arming if not tripped
            {%{stage_state | armed_at: nil}, shed_acc}
        end
      end)

    {new_state, total_new_shed}
  end
end
