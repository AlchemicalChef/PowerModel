defmodule PowerModel.Controls.FACTSController do
  @moduledoc """
  Flexible AC Transmission System (FACTS) controller.

  Controls series-connected devices that modify effective impedance or
  phase angle of a transmission line to manage power flow.

  ## TCSC Mode (Thyristor-Controlled Series Capacitor)

  Adjusts the effective series reactance to maintain a target power flow:

      x_effective = x_line * (1 - compensation_pct / 100)

  The controller modulates `compensation_pct` using a PI controller
  to drive the measured flow toward the target.

  ## Phase Shifter Mode

  Adjusts the phase angle to maintain a target MW flow:

      phase_angle adjusts via PI to track target_mw

  Both modes use a first-order lag to model device response dynamics,
  with output clamped to device physical limits.
  """

  defstruct [
    :device_type,        # "TCSC" | "phase_shifter"
    :x_set_pu,           # current effective reactance (TCSC)
    :angle_set_deg,      # current phase angle (phase shifter)
    :x_line_pu,          # nominal line reactance (TCSC)
    :x_min_pu,           # minimum effective reactance
    :x_max_pu,           # maximum effective reactance
    :angle_min_deg,      # minimum phase angle
    :angle_max_deg,      # maximum phase angle
    :target_mw,          # power flow target (MW)
    :kp,                 # proportional gain
    :ki,                 # integral gain
    :integral,           # integral accumulator
    :tau_s               # response time constant (seconds)
  ]

  @doc """
  Initialize FACTS controller from a FACTS device schema map.

  Expects fields matching the `FACTSDevice` schema:
    * `:device_type` — `"TCSC"` or `"phase_shifter"`
    * `:x_min_pu`, `:x_max_pu`, `:x_set_pu` — reactance limits/setpoint
    * `:angle_min_deg`, `:angle_max_deg`, `:angle_set_deg` — angle limits/setpoint
    * `:target_mw` — desired power flow (optional, default 0.0)

  ## Options
    * `:kp` — proportional gain (default 0.1)
    * `:ki` — integral gain (default 0.01)
    * `:tau_s` — response time constant (default 0.1 s)
  """
  def init(device, opts \\ []) do
    device_type = Map.get(device, :device_type, "TCSC")

    kp = Keyword.get(opts, :kp, 0.1)
    ki = Keyword.get(opts, :ki, 0.01)
    tau_s = Keyword.get(opts, :tau_s, 0.1)

    %__MODULE__{
      device_type: device_type,
      x_set_pu: Map.get(device, :x_set_pu, 0.05),
      angle_set_deg: Map.get(device, :angle_set_deg, 0.0),
      x_line_pu: Map.get(device, :x_line_pu) || Map.get(device, :x_set_pu, 0.05),
      x_min_pu: Map.get(device, :x_min_pu, 0.01),
      x_max_pu: Map.get(device, :x_max_pu, 0.1),
      angle_min_deg: Map.get(device, :angle_min_deg, -30.0),
      angle_max_deg: Map.get(device, :angle_max_deg, 30.0),
      target_mw: Map.get(device, :target_mw, 0.0),
      kp: kp,
      ki: ki,
      integral: 0.0,
      tau_s: max(tau_s, 0.001)
    }
  end

  @doc """
  Advance the FACTS controller by one timestep.

  Given the current measured power flow and target, computes the
  new setpoint for either reactance (TCSC) or phase angle (phase shifter).

  Returns `{new_state, output}` where output is:
    * For TCSC: `{:x_pu, new_x_effective}`
    * For phase_shifter: `{:angle_deg, new_angle}`
  """
  def step(%__MODULE__{device_type: "TCSC"} = state, p_flow_mw, target_mw, dt_s) do
    error = target_mw - p_flow_mw

    # PI controller
    new_integral = state.integral + error * dt_s
    correction = state.kp * error + state.ki * new_integral

    # Normalize correction by the line's base MW capacity.
    # P_line ~ V^2 / X, so for a 100 MVA base: P_base ~ base_mva / x_line_pu.
    # The correction (in MW) is converted to pu reactance change by dividing
    # by the line's approximate power capacity.
    base_mva = 100.0
    p_line_base = base_mva / max(state.x_line_pu, 0.001)
    x_target = state.x_set_pu - correction * state.x_line_pu / p_line_base

    # Clamp to limits
    x_target = x_target |> max(state.x_min_pu) |> min(state.x_max_pu)

    # First-order lag
    alpha = 1.0 - :math.exp(-dt_s / state.tau_s)
    new_x = state.x_set_pu + alpha * (x_target - state.x_set_pu)
    new_x = new_x |> max(state.x_min_pu) |> min(state.x_max_pu)

    new_state = %{state | x_set_pu: new_x, integral: new_integral}
    {new_state, {:x_pu, new_x}}
  end

  def step(%__MODULE__{device_type: "phase_shifter"} = state, p_flow_mw, target_mw, dt_s) do
    error = target_mw - p_flow_mw

    # PI controller
    new_integral = state.integral + error * dt_s
    correction = state.kp * error + state.ki * new_integral

    # Normalize correction from MW error to degrees.
    # Phase shifter sensitivity: P ~ V^2 * sin(angle) / X.
    # For small angles: dP/d(angle) ~ base_mva / x_line_pu (in MW/rad).
    # Convert to degrees: dP/d(angle_deg) ~ base_mva / x_line_pu / (180/pi).
    base_mva = 100.0
    sensitivity_mw_per_deg = base_mva / max(state.x_line_pu, 0.001) / (180.0 / :math.pi())
    angle_target = state.angle_set_deg + correction / max(sensitivity_mw_per_deg, 0.001)

    # Clamp to limits
    angle_target = angle_target |> max(state.angle_min_deg) |> min(state.angle_max_deg)

    # First-order lag
    alpha = 1.0 - :math.exp(-dt_s / state.tau_s)
    new_angle = state.angle_set_deg + alpha * (angle_target - state.angle_set_deg)
    new_angle = new_angle |> max(state.angle_min_deg) |> min(state.angle_max_deg)

    new_state = %{state | angle_set_deg: new_angle, integral: new_integral}
    {new_state, {:angle_deg, new_angle}}
  end

  def step(%__MODULE__{} = state, _p_flow_mw, _target_mw, _dt_s) do
    # Unknown device type — return current setpoint unchanged
    output =
      case state.device_type do
        "TCSC" -> {:x_pu, state.x_set_pu}
        "phase_shifter" -> {:angle_deg, state.angle_set_deg}
        _ -> {:x_pu, state.x_set_pu}
      end

    {state, output}
  end
end
