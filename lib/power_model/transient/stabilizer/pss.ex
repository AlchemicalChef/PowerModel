defmodule PowerModel.Transient.Stabilizer.PSS do
  @moduledoc """
  Power System Stabilizer (PSS) — washout + lead-lag compensator.

  Provides supplementary damping by adding a stabilizing signal to the
  exciter voltage reference. The PSS senses rotor speed deviation and
  produces a phase-shifted signal that creates a component of electrical
  torque in phase with speed deviation (damping torque).

  Two state variables:
    - `x_washout` — washout filter state
    - `x_lead`    — lead-lag compensator state

  Signal flow:

      speed_input = omega - 1.0    (per-unit speed deviation)

      Washout filter (high-pass, removes DC):
        dx_washout/dt = (K_pss * speed_input - x_washout) / T_washout

      Lead-lag compensator:
        v_washout = K_pss * speed_input - x_washout  (or equivalently: T_washout * dx_washout/dt)
        ... but using state-space form:
        dx_lead/dt = ((1 + T1/T2) * x_washout - x_lead) / T2

      Output:
        v_pss = x_lead   (additive to exciter V_ref)

  The washout filter ensures no steady-state output (PSS only responds
  to transients). The lead-lag block provides phase advance to compensate
  for GEP(s) phase lag.

  Default parameters (IEEE Type PSS1A):
    - K_pss    = 10.0    (stabilizer gain)
    - T_washout = 5.0 s  (washout time constant)
    - T1       = 0.1 s   (lead time constant)
    - T2       = 0.05 s  (lag time constant)
    - v_pss_max = 0.1 pu (output limit)
    - v_pss_min = -0.1 pu

  Reference: IEEE Std 421.5-2016, Section 8 (PSS Models).
  """

  defstruct [
    :x_washout,   # washout filter state
    :x_lead,      # lead-lag compensator state
    :k_pss,       # stabilizer gain
    :t_washout,   # washout time constant (seconds)
    :t1,          # lead time constant (seconds)
    :t2,          # lag time constant (seconds)
    :v_pss_max,   # maximum PSS output (pu)
    :v_pss_min    # minimum PSS output (pu)
  ]

  @default_k_pss 10.0
  @default_t_washout 5.0
  @default_t1 0.1
  @default_t2 0.05
  @default_v_pss_max 0.1
  @default_v_pss_min -0.1

  @doc """
  Initialize PSS state from generator parameters.

  Accepts optional PSS parameters as a map. At steady state (omega = 1.0),
  all PSS states are zero (no output).
  """
  def init(params \\ %{}) do
    %__MODULE__{
      x_washout: 0.0,
      x_lead: 0.0,
      k_pss: Map.get(params, :k_pss, @default_k_pss),
      t_washout: max(Map.get(params, :t_washout, @default_t_washout), 0.01),
      t1: max(Map.get(params, :t1, @default_t1), 0.001),
      t2: max(Map.get(params, :t2, @default_t2), 0.001),
      v_pss_max: Map.get(params, :v_pss_max, @default_v_pss_max),
      v_pss_min: Map.get(params, :v_pss_min, @default_v_pss_min)
    }
  end

  @doc """
  Compute state derivatives for the PSS.

  Input is the per-unit speed deviation (omega - 1.0).
  Returns `{dx_washout, dx_lead}`.
  """
  def derivatives(%__MODULE__{} = pss, omega_dev) do
    # Washout filter (high-pass):
    #   dx_washout/dt = (K_pss * omega_dev - x_washout) / T_washout
    #   v_washout = K_pss * omega_dev - x_washout  (output, = T_washout * dx_washout/dt)
    dx_washout = (pss.k_pss * omega_dev - pss.x_washout) / pss.t_washout
    v_washout = pss.k_pss * omega_dev - pss.x_washout

    # Lead-lag compensator (1 + sT1)/(1 + sT2):
    #   dx_lead/dt = (v_washout - x_lead) / T2
    dx_lead = (v_washout - pss.x_lead) / pss.t2

    {dx_washout, dx_lead}
  end

  @doc """
  Compute the washout filter output (intermediate signal).
  """
  def washout_output(%__MODULE__{} = pss, omega_dev) do
    pss.k_pss * omega_dev - pss.x_washout
  end

  @doc """
  Return current PSS output voltage signal.

  The lead-lag output is: v_pss = x_lead + (T1/T2) * (v_washout - x_lead)
  This provides phase lead when T1 > T2.

  Output is clamped to prevent excessive modulation.
  """
  def v_pss(%__MODULE__{} = pss, omega_dev \\ nil) do
    # When omega_dev is available, compute full lead-lag output
    # Otherwise, use x_lead as approximation (for backward compat)
    raw = case omega_dev do
      nil ->
        pss.x_lead

      dev ->
        v_wo = washout_output(pss, dev)
        pss.x_lead + (pss.t1 / pss.t2) * (v_wo - pss.x_lead)
    end

    raw
    |> max(pss.v_pss_min)
    |> min(pss.v_pss_max)
  end

  @doc """
  Advance PSS state by one Euler step.
  """
  def step_euler(%__MODULE__{} = pss, omega_dev, dt) do
    {dx_washout, dx_lead} = derivatives(pss, omega_dev)

    %{pss |
      x_washout: pss.x_washout + dx_washout * dt,
      x_lead: pss.x_lead + dx_lead * dt
    }
  end

  @doc """
  Advance PSS state by one trapezoidal corrector step.
  """
  def step_trapezoidal(%__MODULE__{} = pss_n, %__MODULE__{} = pss_pred, omega_dev_n, omega_dev_pred, dt) do
    {dx_wo_n, dx_lead_n} = derivatives(pss_n, omega_dev_n)
    {dx_wo_pred, dx_lead_pred} = derivatives(pss_pred, omega_dev_pred)

    %{pss_n |
      x_washout: pss_n.x_washout + dt / 2.0 * (dx_wo_n + dx_wo_pred),
      x_lead: pss_n.x_lead + dt / 2.0 * (dx_lead_n + dx_lead_pred)
    }
  end
end
