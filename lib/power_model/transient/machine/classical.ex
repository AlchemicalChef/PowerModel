defmodule PowerModel.Transient.Machine.Classical do
  @moduledoc """
  Classical synchronous machine model.

  Represents each generator as a constant voltage source E' behind
  transient reactance X'd. Two state variables per machine:

      d(delta)/dt = omega_base * (omega - 1.0)
      d(omega)/dt = (P_mech - P_elec - D * (omega - 1.0)) / (2 * H)

  The electrical power P_elec is computed from the reduced admittance
  matrix Y_red and the rotor angles of all machines:

      P_elec_i = E_i^2 * G_ii + sum_{j!=i} E_i * E_j *
                 (B_ij * sin(delta_i - delta_j) + G_ij * cos(delta_i - delta_j))

  This model is valid for the first few seconds after a disturbance,
  before exciter and governor effects become significant.
  """

  @omega_base 2.0 * :math.pi() * 60.0

  @doc """
  Compute electrical power output for all generators.

  Uses the reduced admittance matrix in sparse COO format.
  Returns a list of P_elec values in pu (parallel to the generator list).
  """
  def compute_p_elec(delta, e_prime, y_red_rows, y_red_cols, y_red_g, y_red_b, n_gen) do
    # Initialize P_elec accumulators
    p_elec = :array.new(n_gen, default: 0.0)

    # Process each non-zero entry in Y_red
    p_elec = Enum.zip([y_red_rows, y_red_cols, y_red_g, y_red_b])
    |> Enum.reduce(p_elec, fn {i, j, g_ij, b_ij}, acc ->
      ei = Enum.at(delta, i)  # Will use arrays for perf
      ej = Enum.at(delta, j)
      e_i = Enum.at(e_prime, i)
      e_j = Enum.at(e_prime, j)

      if i == j do
        # Diagonal: P += E_i^2 * G_ii
        p_add = e_i * e_i * g_ij
        array_add(acc, i, p_add)
      else
        # Off-diagonal: P_i += E_i * E_j * (B_ij * sin(d_i - d_j) + G_ij * cos(d_i - d_j))
        d_ij = ei - ej
        p_add = e_i * e_j * (b_ij * :math.sin(d_ij) + g_ij * :math.cos(d_ij))
        array_add(acc, i, p_add)
      end
    end)

    :array.to_list(p_elec)
  end

  @doc """
  Compute derivatives (d_delta/dt, d_omega/dt) for all generators.
  """
  def derivatives(_delta, omega, p_mech, p_elec, h, d_coeff, n_gen) do
    d_delta = for i <- 0..(n_gen - 1) do
      @omega_base * (Enum.at(omega, i) - 1.0)
    end

    d_omega = for i <- 0..(n_gen - 1) do
      hi = Enum.at(h, i)
      if hi > 0.0 do
        (Enum.at(p_mech, i) - Enum.at(p_elec, i) - Enum.at(d_coeff, i) * (Enum.at(omega, i) - 1.0)) / (2.0 * hi)
      else
        0.0
      end
    end

    {d_delta, d_omega}
  end

  @doc """
  Single Euler forward step (used as predictor in trapezoidal method).
  """
  def euler_step(delta, omega, d_delta, d_omega, dt) do
    new_delta = Enum.zip(delta, d_delta) |> Enum.map(fn {x, dx} -> x + dx * dt end)
    new_omega = Enum.zip(omega, d_omega) |> Enum.map(fn {x, dx} -> x + dx * dt end)
    {new_delta, new_omega}
  end

  @doc """
  Trapezoidal corrector step.
  x_{n+1} = x_n + dt/2 * (f(x_n) + f(x_{n+1}_predicted))
  """
  def trapezoidal_correct(x_n, dx_n, dx_pred, dt) do
    Enum.zip([x_n, dx_n, dx_pred])
    |> Enum.map(fn {x, f0, f1} -> x + dt / 2.0 * (f0 + f1) end)
  end

  @doc """
  Run the classical model simulation entirely in Elixir.
  Used for small systems and testing. For large grids, use the Rust NIF.

  Returns a list of trajectory points: `[%{t: float, delta: [float], omega: [float]}]`
  """
  def simulate(state, n_steps, output_every \\ 1) do
    # Sort events by time
    events = Enum.sort_by(state.events, & &1.time)

    {trajectory, _final_state} =
      Enum.reduce(1..n_steps, {[snapshot(state, 0)], state}, fn step, {traj, st} ->
        t = step * st.dt

        # Process events at this timestep
        p_mech = apply_events(st.p_mech, events, t, st.dt)

        # Compute P_elec at current state
        p_elec = compute_p_elec(st.delta, st.e_prime,
                                st.y_red_rows, st.y_red_cols,
                                st.y_red_g, st.y_red_b, st.n_gen)

        # Euler predictor
        {d_delta_0, d_omega_0} = derivatives(st.delta, st.omega, p_mech, p_elec, st.h, st.d, st.n_gen)
        {pred_delta, pred_omega} = euler_step(st.delta, st.omega, d_delta_0, d_omega_0, st.dt)

        # Compute P_elec at predicted state
        p_elec_pred = compute_p_elec(pred_delta, st.e_prime,
                                     st.y_red_rows, st.y_red_cols,
                                     st.y_red_g, st.y_red_b, st.n_gen)

        # Trapezoidal corrector
        {d_delta_1, d_omega_1} = derivatives(pred_delta, pred_omega, p_mech, p_elec_pred, st.h, st.d, st.n_gen)
        new_delta = trapezoidal_correct(st.delta, d_delta_0, d_delta_1, st.dt)
        new_omega = trapezoidal_correct(st.omega, d_omega_0, d_omega_1, st.dt)

        st = %{st | delta: new_delta, omega: new_omega, p_mech: p_mech, t: t}

        if rem(step, output_every) == 0 do
          {[snapshot(st, step) | traj], st}
        else
          {traj, st}
        end
      end)

    Enum.reverse(trajectory)
  end

  defp snapshot(state, _step) do
    %{
      t: state.t,
      delta: state.delta,
      omega: state.omega,
      frequency_hz: Enum.map(state.omega, &(&1 * 60.0))
    }
  end

  defp apply_events(p_mech, events, t, dt) do
    Enum.reduce(events, p_mech, fn event, pm ->
      if event.time > t - dt and event.time <= t do
        List.replace_at(pm, event.gen_index, event.p_mech_new)
      else
        pm
      end
    end)
  end

  defp array_add(arr, idx, val) do
    :array.set(idx, :array.get(idx, arr) + val, arr)
  end
end
