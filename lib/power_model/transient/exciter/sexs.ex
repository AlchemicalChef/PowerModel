defmodule PowerModel.Transient.Exciter.SEXS do
  @moduledoc """
  Simplified Excitation System (SEXS).

  A first-order exciter model with single gain and time constant:

      dE_fd/dt = (K * (V_ref - V_t + V_pss) - E_fd) / T_E

  where:
  - E_fd = field voltage (output, affects E' in detailed machine models)
  - K = exciter gain (typical 20-200)
  - T_E = exciter time constant (typical 0.1-1.0 s)
  - V_ref = voltage reference setpoint (typically 1.0 pu)
  - V_t = terminal voltage (from network solution)
  - V_pss = PSS supplementary signal (0 when no PSS)

  For the classical machine model (constant E'), this exciter modifies
  the E' magnitude over time in response to terminal voltage deviations.

  ## State
  Single state variable: `e_fd` (field voltage in pu)
  """

  defstruct [
    :e_fd,       # field voltage (pu)
    :v_ref,      # voltage reference setpoint (pu)
    :k,          # exciter gain
    :t_e,        # exciter time constant (seconds)
    :e_fd_min,   # field voltage lower limit
    :e_fd_max    # field voltage upper limit
  ]

  @default_k 100.0
  @default_t_e 0.5
  @default_e_fd_min -5.0
  @default_e_fd_max 5.0

  @doc """
  Initialize exciter state from generator parameters.
  """
  def init(gen) do
    v_set = Map.get(gen, :v_set_pu) || 1.0

    %__MODULE__{
      e_fd: v_set,
      v_ref: v_set,
      k: @default_k,
      t_e: @default_t_e,
      e_fd_min: @default_e_fd_min,
      e_fd_max: @default_e_fd_max
    }
  end

  @doc """
  Compute the derivative of field voltage.
  """
  def derivative(%__MODULE__{} = state, v_terminal, v_pss \\ 0.0) do
    error = state.v_ref - v_terminal + v_pss
    (state.k * error - state.e_fd) / max(state.t_e, 0.001)
  end

  @doc """
  Euler integration step for the exciter.
  """
  def step(%__MODULE__{} = state, v_terminal, dt, v_pss \\ 0.0) do
    d_efd = derivative(state, v_terminal, v_pss)
    new_efd = state.e_fd + d_efd * dt
    new_efd = max(state.e_fd_min, min(state.e_fd_max, new_efd))
    %{state | e_fd: new_efd}
  end
end
