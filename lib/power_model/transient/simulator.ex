defmodule PowerModel.Transient.Simulator do
  @moduledoc """
  Enhanced transient stability simulator with governor, PSS, and IBR models.

  Extends the classical machine model simulation loop to include:
    - **Governor response**: TGOV1 (steam), HYGOV (hydro), GAST (gas turbine)
      adjust mechanical power in response to speed deviations.
    - **Power System Stabilizer (PSS)**: Washout + lead-lag compensator adds
      supplementary damping torque through exciter voltage modulation.
    - **Inverter-Based Resources (IBR)**: Grid-following inverters inject
      constant P/Q with LVRT protection; grid-forming inverters use virtual
      synchronous machine (VSM) emulation.

  ## Simulation Loop

  At each timestep (trapezoidal predictor-corrector):

  1. Apply scheduled events (fault on/off, generator trips)
  2. Compute P_elec from Y_reduced and rotor angles (classical model)
  3. Update governor states → new P_mech values replace constant P_mech
  4. Update PSS states → v_pss modifies damping term
  5. Compute swing equation derivatives with updated P_mech and PSS
  6. Euler predictor step for all states
  7. Recompute derivatives at predicted state
  8. Trapezoidal corrector for all states
  9. Step IBR models (separate from swing equation)
  10. Check for OOS

  ## State Organization

  Governor and PSS states are stored in parallel lists indexed by generator:
    - `gov_states` — list of governor structs (or nil for no governor)
    - `pss_states` — list of PSS structs (or nil for no PSS)
    - `ibr_states` — list of IBR structs (or nil for synchronous machines)

  ## Usage

      state = Simulator.init(generators, solution, opts)
      trajectory = Simulator.simulate(state, n_steps, opts)
  """

  alias PowerModel.Transient.Machine.{Classical, IBR}
  alias PowerModel.Transient.Governor.{TGOV1, HYGOV, GAST}
  alias PowerModel.Transient.Stabilizer.PSS
  alias PowerModel.Transient.State

  defstruct [
    # Core state (from State struct)
    :t,
    :dt,
    :n_gen,
    :gen_ids,
    :gen_bus_ids,
    :delta,
    :omega,
    :p_mech,
    :e_prime,
    :h,
    :d,
    :y_red_rows,
    :y_red_cols,
    :y_red_g,
    :y_red_b,
    :base_mva,
    :events,
    :tripped_gens,

    # Extended state
    :gov_states,   # [gov_struct | nil] per generator
    :pss_states,   # [pss_struct | nil] per generator
    :ibr_states,   # [ibr_struct | nil] per generator (mutually exclusive with sync)
    :gen_types     # [:sync | :ibr] per generator
  ]

  @doc """
  Initialize an enhanced simulator state from a base transient State.

  Attaches governor, PSS, and IBR models to each generator based on
  their parameters and fuel type.

  ## Options
    - `:governors` — `:auto` (default) or `:none` to disable
    - `:pss` — `:auto` (default) or `:none` to disable
    - `:ibr` — `:auto` (default) or `:none` to disable
    - `:governor_map` — map of gen_index => governor struct (overrides auto)
    - `:pss_map` — map of gen_index => pss struct (overrides auto)
  """
  def from_state(%State{} = base_state, generators, opts \\ []) do
    enable_gov = Keyword.get(opts, :governors, :auto)
    enable_pss = Keyword.get(opts, :pss, :auto)
    enable_ibr = Keyword.get(opts, :ibr, :auto)
    gov_map = Keyword.get(opts, :governor_map, %{})
    pss_map = Keyword.get(opts, :pss_map, %{})

    # Sort generators to match State ordering
    sorted_gens = generators
    |> Enum.filter(fn g ->
      h = Map.get(g, :inertia_h) || 0.0
      h > 0.0 and Map.get(g, :status, "in_service") == "in_service"
    end)
    |> Enum.sort_by(& &1.id)

    # Build per-generator auxiliary state
    {gov_states, pss_states, ibr_states, gen_types} =
      sorted_gens
      |> Enum.with_index()
      |> Enum.map(fn {gen, idx} ->
        p_mech_pu = Enum.at(base_state.p_mech, idx)

        gen_with_pmech = Map.put(gen, :p_mech_pu, p_mech_pu)

        # Determine if this is an IBR
        is_ibr = enable_ibr == :auto and IBR.ibr_candidate?(gen)

        if is_ibr do
          ibr = IBR.init(gen_with_pmech)
          {nil, nil, ibr, :ibr}
        else
          # Governor
          gov = cond do
            Map.has_key?(gov_map, idx) -> Map.get(gov_map, idx)
            enable_gov == :none -> nil
            true -> auto_governor(gen_with_pmech)
          end

          # PSS
          pss = cond do
            Map.has_key?(pss_map, idx) -> Map.get(pss_map, idx)
            enable_pss == :none -> nil
            true -> auto_pss(gen)
          end

          {gov, pss, nil, :sync}
        end
      end)
      |> unzip4()

    %__MODULE__{
      t: base_state.t,
      dt: base_state.dt,
      n_gen: base_state.n_gen,
      gen_ids: base_state.gen_ids,
      gen_bus_ids: base_state.gen_bus_ids,
      delta: base_state.delta,
      omega: base_state.omega,
      p_mech: base_state.p_mech,
      e_prime: base_state.e_prime,
      h: base_state.h,
      d: base_state.d,
      y_red_rows: base_state.y_red_rows,
      y_red_cols: base_state.y_red_cols,
      y_red_g: base_state.y_red_g,
      y_red_b: base_state.y_red_b,
      base_mva: base_state.base_mva,
      events: base_state.events,
      tripped_gens: base_state.tripped_gens,
      gov_states: gov_states,
      pss_states: pss_states,
      ibr_states: ibr_states,
      gen_types: gen_types
    }
  end

  @doc """
  Run enhanced simulation with governor, PSS, and IBR models.

  Returns a list of trajectory points:
  `[%{t: float, delta: [float], omega: [float], frequency_hz: [float], p_mech: [float]}]`

  ## Options
    - `:output_every` — decimation factor for output (default 1)
  """
  def simulate(%__MODULE__{} = state, n_steps, opts \\ []) do
    output_every = Keyword.get(opts, :output_every, 1)
    events = Enum.sort_by(state.events, & &1.time)

    {trajectory, _final_state} =
      Enum.reduce(1..n_steps, {[snapshot(state)], state}, fn step, {traj, st} ->
        t = step * st.dt

        # 1. Apply scheduled events (same as classical)
        p_mech_events = apply_events(st.p_mech, events, t, st.dt)

        # 2. Compute P_elec from Y_reduced (classical model)
        p_elec = Classical.compute_p_elec(
          st.delta, st.e_prime,
          st.y_red_rows, st.y_red_cols,
          st.y_red_g, st.y_red_b, st.n_gen
        )

        # 3. Update governor states → get new P_mech values
        {gov_states_0, p_mech_gov} = update_governors(st.gov_states, st.omega, p_mech_events, st.gen_types)

        # 4. Get PSS damping contribution
        pss_damping = compute_pss_damping(st.pss_states, st.omega)

        # 5. Compute swing equation derivatives with governor P_mech and PSS damping
        effective_d = add_pss_damping(st.d, pss_damping)
        {d_delta_0, d_omega_0} = Classical.derivatives(
          st.delta, st.omega, p_mech_gov, p_elec, st.h, effective_d, st.n_gen
        )

        # 6. Euler predictor step
        {pred_delta, pred_omega} = Classical.euler_step(st.delta, st.omega, d_delta_0, d_omega_0, st.dt)

        # Euler predict governor and PSS states
        gov_states_pred = euler_step_governors(gov_states_0, st.omega, st.dt, st.gen_types)
        pss_states_pred = euler_step_pss(st.pss_states, st.omega, st.dt)

        # 7. Recompute at predicted state
        p_elec_pred = Classical.compute_p_elec(
          pred_delta, st.e_prime,
          st.y_red_rows, st.y_red_cols,
          st.y_red_g, st.y_red_b, st.n_gen
        )

        {_gov_states_pred2, p_mech_pred} = update_governors(gov_states_pred, pred_omega, p_mech_events, st.gen_types)
        pss_damping_pred = compute_pss_damping(pss_states_pred, pred_omega)
        effective_d_pred = add_pss_damping(st.d, pss_damping_pred)

        {d_delta_1, d_omega_1} = Classical.derivatives(
          pred_delta, pred_omega, p_mech_pred, p_elec_pred, st.h, effective_d_pred, st.n_gen
        )

        # 8. Trapezoidal corrector
        new_delta = Classical.trapezoidal_correct(st.delta, d_delta_0, d_delta_1, st.dt)
        new_omega = Classical.trapezoidal_correct(st.omega, d_omega_0, d_omega_1, st.dt)

        # Trapezoidal correct governor states
        new_gov_states = trapezoidal_step_governors(
          gov_states_0, gov_states_pred, st.omega, new_omega, st.dt, st.gen_types
        )

        # Trapezoidal correct PSS states
        new_pss_states = trapezoidal_step_pss(
          st.pss_states, pss_states_pred, st.omega, new_omega, st.dt
        )

        # 9. Step IBR models
        {new_ibr_states, _ibr_p, _ibr_q} = step_ibr_models(st.ibr_states, st.e_prime, st.dt)

        # Update mechanical power from governors for next step
        new_p_mech = build_p_mech(new_gov_states, p_mech_events, st.gen_types)

        st = %{st |
          delta: new_delta,
          omega: new_omega,
          p_mech: new_p_mech,
          t: t,
          gov_states: new_gov_states,
          pss_states: new_pss_states,
          ibr_states: new_ibr_states
        }

        if rem(step, output_every) == 0 do
          {[snapshot(st) | traj], st}
        else
          {traj, st}
        end
      end)

    Enum.reverse(trajectory)
  end

  # --- Governor helpers ---

  defp update_governors(gov_states, _omega, p_mech_events, gen_types) do
    {new_govs, new_pmechs} =
      gov_states
      |> Enum.with_index()
      |> Enum.map(fn {gov, idx} ->
        case {gov, Enum.at(gen_types, idx)} do
          {nil, _} ->
            {nil, Enum.at(p_mech_events, idx)}

          {%TGOV1{} = g, :sync} ->
            {g, TGOV1.p_mech(g)}

          {%HYGOV{} = g, :sync} ->
            {g, HYGOV.p_mech(g)}

          {%GAST{} = g, :sync} ->
            {g, GAST.p_mech(g)}

          {_, _} ->
            {gov, Enum.at(p_mech_events, idx)}
        end
      end)
      |> Enum.unzip()

    {new_govs, new_pmechs}
  end

  defp euler_step_governors(gov_states, omega, dt, gen_types) do
    gov_states
    |> Enum.with_index()
    |> Enum.map(fn {gov, idx} ->
      w = Enum.at(omega, idx)
      case {gov, Enum.at(gen_types, idx)} do
        {nil, _} -> nil
        {%TGOV1{} = g, :sync} -> TGOV1.step_euler(g, w, dt)
        {%HYGOV{} = g, :sync} -> HYGOV.step_euler(g, w, dt)
        {%GAST{} = g, :sync} -> GAST.step_euler(g, w, dt)
        {_, _} -> gov
      end
    end)
  end

  defp trapezoidal_step_governors(gov_n, gov_pred, omega_n, omega_pred, dt, gen_types) do
    Enum.zip([gov_n, gov_pred])
    |> Enum.with_index()
    |> Enum.map(fn {{gn, gp}, idx} ->
      wn = Enum.at(omega_n, idx)
      wp = Enum.at(omega_pred, idx)
      case {gn, Enum.at(gen_types, idx)} do
        {nil, _} -> nil
        {%TGOV1{}, :sync} -> TGOV1.step_trapezoidal(gn, gp, wn, wp, dt)
        {%HYGOV{}, :sync} -> HYGOV.step_trapezoidal(gn, gp, wn, wp, dt)
        {%GAST{}, :sync} -> GAST.step_trapezoidal(gn, gp, wn, wp, dt)
        {_, _} -> gn
      end
    end)
  end

  defp build_p_mech(gov_states, p_mech_events, gen_types) do
    gov_states
    |> Enum.with_index()
    |> Enum.map(fn {gov, idx} ->
      case {gov, Enum.at(gen_types, idx)} do
        {nil, _} -> Enum.at(p_mech_events, idx)
        {%TGOV1{} = g, :sync} -> TGOV1.p_mech(g)
        {%HYGOV{} = g, :sync} -> HYGOV.p_mech(g)
        {%GAST{} = g, :sync} -> GAST.p_mech(g)
        {_, _} -> Enum.at(p_mech_events, idx)
      end
    end)
  end

  # --- PSS helpers ---

  defp compute_pss_damping(pss_states, omega) do
    pss_states
    |> Enum.with_index()
    |> Enum.map(fn {pss, idx} ->
      case pss do
        nil -> 0.0
        %PSS{} = p ->
          # PSS output acts as additional damping torque.
          # v_pss is proportional to speed deviation, so it effectively adds
          # to the damping coefficient D in: D * (omega - 1).
          omega_dev = Enum.at(omega, idx) - 1.0
          v = PSS.v_pss(p, omega_dev)
          # Convert v_pss to equivalent damping: D_pss = v_pss / (omega - 1)
          if abs(omega_dev) > 1.0e-10 do
            v / omega_dev
          else
            0.0
          end
      end
    end)
  end

  defp add_pss_damping(d_base, pss_damping) do
    Enum.zip(d_base, pss_damping)
    |> Enum.map(fn {d, pss_d} -> d + pss_d end)
  end

  defp euler_step_pss(pss_states, omega, dt) do
    pss_states
    |> Enum.with_index()
    |> Enum.map(fn {pss, idx} ->
      case pss do
        nil -> nil
        %PSS{} = p ->
          omega_dev = Enum.at(omega, idx) - 1.0
          PSS.step_euler(p, omega_dev, dt)
      end
    end)
  end

  defp trapezoidal_step_pss(pss_n, pss_pred, omega_n, omega_pred, dt) do
    Enum.zip([pss_n, pss_pred])
    |> Enum.with_index()
    |> Enum.map(fn {{pn, pp}, idx} ->
      case pn do
        nil -> nil
        %PSS{} ->
          omega_dev_n = Enum.at(omega_n, idx) - 1.0
          omega_dev_pred = Enum.at(omega_pred, idx) - 1.0
          PSS.step_trapezoidal(pn, pp, omega_dev_n, omega_dev_pred, dt)
      end
    end)
  end

  # --- IBR helpers ---

  defp step_ibr_models(ibr_states, e_prime, dt) do
    {new_states, ps, qs} =
      ibr_states
      |> Enum.with_index()
      |> Enum.map(fn {ibr, idx} ->
        case ibr do
          nil ->
            {nil, 0.0, 0.0}

          %IBR{} = i ->
            # Use E' as approximate terminal voltage
            v_term = Enum.at(e_prime, idx)
            IBR.step(i, v_term, dt)
        end
      end)
      |> Enum.reduce({[], [], []}, fn {ibr, p, q}, {is, ps, qs} ->
        {[ibr | is], [p | ps], [q | qs]}
      end)

    {Enum.reverse(new_states), Enum.reverse(ps), Enum.reverse(qs)}
  end

  # --- Event helpers ---

  defp apply_events(p_mech, events, t, dt) do
    Enum.reduce(events, p_mech, fn event, pm ->
      if event.time > t - dt and event.time <= t do
        List.replace_at(pm, event.gen_index, event.p_mech_new)
      else
        pm
      end
    end)
  end

  # --- Output ---

  defp snapshot(%__MODULE__{} = state) do
    %{
      t: state.t,
      delta: state.delta,
      omega: state.omega,
      frequency_hz: Enum.map(state.omega, &(&1 * 60.0)),
      p_mech: state.p_mech
    }
  end

  # --- Auto-assignment ---

  defp auto_governor(gen) do
    fuel = Map.get(gen, :fuel_type, "")
    prime_mover = Map.get(gen, :prime_mover, "")

    cond do
      # Hydro units
      fuel in ["WAT", "WH"] or prime_mover in ["HY", "PS"] ->
        HYGOV.init(gen)

      # Gas turbines
      fuel in ["NG", "OG", "BFG", "LFG"] and prime_mover in ["GT", "IC", "CT", "CA"] ->
        GAST.init(gen)

      # Steam units (coal, nuclear, oil, geothermal, biomass, waste)
      fuel in ["NUC", "COL", "DFO", "RFO", "PET", "GEO", "WDS", "BLQ", "PC", "LIG", "SUB", "BIT", "AB", "MSW", "OBS", "WDL", "TDF"] ->
        TGOV1.init(gen)

      # Combined cycle steam portion
      prime_mover in ["ST", "CS"] ->
        TGOV1.init(gen)

      # Default: TGOV1 for any synchronous machine
      true ->
        TGOV1.init(gen)
    end
  end

  defp auto_pss(gen) do
    # Only attach PSS to large synchronous generators (> 50 MW)
    p_max = Map.get(gen, :p_max_mw, 0.0)

    if p_max >= 50.0 do
      PSS.init()
    else
      nil
    end
  end

  # Enum.unzip for 4-tuples
  defp unzip4(list) do
    Enum.reduce(Enum.reverse(list), {[], [], [], []}, fn {a, b, c, d}, {as, bs, cs, ds} ->
      {[a | as], [b | bs], [c | cs], [d | ds]}
    end)
  end
end
