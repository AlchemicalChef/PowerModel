defmodule PowerModel.Transient.State do
  @moduledoc """
  State struct for transient stability simulation.

  Holds per-generator dynamic state (rotor angles, speeds, mechanical power),
  machine parameters, the reduced admittance matrix, and scheduled events.
  """

  defstruct [
    :t,              # current simulation time (seconds)
    :dt,             # timestep size (seconds)
    :n_gen,          # number of generators
    :gen_ids,        # ordered list of generator IDs
    :gen_bus_ids,    # ordered list of bus IDs (parallel to gen_ids)
    :delta,          # rotor angles [n_gen] (radians)
    :omega,          # rotor speeds [n_gen] (pu, 1.0 = synchronous)
    :p_mech,         # mechanical power [n_gen] (pu on system base)
    :e_prime,        # internal voltage magnitude [n_gen] (pu)
    :h,              # inertia constants [n_gen] (seconds)
    :d,              # damping coefficients [n_gen]
    :y_red_rows,     # reduced Y-bus COO row indices
    :y_red_cols,     # reduced Y-bus COO column indices
    :y_red_g,        # reduced Y-bus conductance values
    :y_red_b,        # reduced Y-bus susceptance values
    :base_mva,       # system MVA base
    :events,         # list of %{time: float, gen_index: int, p_mech_new: float}
    :trajectory,     # accumulated [{t, deltas, omegas}]
    :tripped_gens    # MapSet of gen indices that have been tripped (OOS/relay)
  ]

  @omega_base 2.0 * :math.pi() * 60.0

  @doc """
  Initialize transient state from a power flow solution and generator data.

  Generators are sorted by ID for consistent indexing. Initial rotor angles
  are computed from the power flow solution: delta = va_rad + arctan(P*X'd / (E'*V)).
  Initial E' is computed from V, P, Q, and X'd.
  """
  def init(generators, solution, base_mva \\ 100.0, opts \\ []) do
    dt = Keyword.get(opts, :dt, 0.005)

    # Only include synchronous generators (inertia > 0)
    sync_gens = generators
    |> Enum.filter(fn g ->
      h = Map.get(g, :inertia_h) || 0.0
      h > 0.0 and (Map.get(g, :status, "in_service") == "in_service")
    end)
    |> Enum.sort_by(& &1.id)

    n_gen = length(sync_gens)
    gen_ids = Enum.map(sync_gens, & &1.id)
    gen_bus_ids = Enum.map(sync_gens, & &1.bus_id)

    # Build bus voltage lookup from solution
    vm_map = Map.new(Enum.zip(solution.bus_ids, solution.vm_pu))
    va_map = Map.new(Enum.zip(solution.bus_ids, solution.va_rad))

    # Compute initial machine states from power flow
    {deltas, omegas, p_mechs, e_primes, h_vals, d_vals} =
      Enum.reduce(sync_gens, {[], [], [], [], [], []}, fn g, {ds, ws, ps, es, hs, dvals} ->
        vm = Map.get(vm_map, g.bus_id, 1.0)
        va = Map.get(va_map, g.bus_id, 0.0)
        p_mw = g.p_max_mw * (Map.get(g, :capacity_factor) || 1.0)
        p_pu = p_mw / base_mva
        x_d_prime = Map.get(g, :x_d_prime_pu) || default_xd_prime(g)

        # Compute internal voltage and angle
        # E' = sqrt((V + Q*X'd/V)^2 + (P*X'd/V)^2)
        # For simplicity with DC solution (V=1, Q=0): E' ≈ sqrt(1 + (P*X'd)^2)
        q_pu = 0.0  # DC solution doesn't give Q; approximate
        e_prime = :math.sqrt(:math.pow(vm + q_pu * x_d_prime / max(vm, 0.01), 2) +
                             :math.pow(p_pu * x_d_prime / max(vm, 0.01), 2))
        e_prime = max(e_prime, 0.5)

        # Rotor angle: delta = va + arcsin(P * X'd / (E' * V))
        sin_arg = p_pu * x_d_prime / max(e_prime * vm, 0.001)
        sin_arg = max(-1.0, min(1.0, sin_arg))
        delta = va + :math.asin(sin_arg)

        h_val = Map.get(g, :inertia_h) || 3.0
        d_val = Map.get(g, :d_factor) || 0.0

        {ds ++ [delta], ws ++ [1.0], ps ++ [p_pu], es ++ [e_prime],
         hs ++ [h_val], dvals ++ [d_val]}
      end)

    %__MODULE__{
      t: 0.0,
      dt: dt,
      n_gen: n_gen,
      gen_ids: gen_ids,
      gen_bus_ids: gen_bus_ids,
      delta: deltas,
      omega: omegas,
      p_mech: p_mechs,
      e_prime: e_primes,
      h: h_vals,
      d: d_vals,
      y_red_rows: [],
      y_red_cols: [],
      y_red_g: [],
      y_red_b: [],
      base_mva: base_mva,
      events: [],
      trajectory: [],
      tripped_gens: MapSet.new()
    }
  end

  @doc "System angular frequency (rad/s)"
  def omega_base, do: @omega_base

  @doc "Look up generator index by ID"
  def gen_index(%__MODULE__{gen_ids: ids}, gen_id) do
    Enum.find_index(ids, &(&1 == gen_id))
  end

  @doc "Schedule a fault event (change P_mech of a generator at a given time)"
  def add_event(%__MODULE__{} = state, time_s, gen_id, new_p_mech_pu) do
    case gen_index(state, gen_id) do
      nil -> state
      idx ->
        event = %{time: time_s, gen_index: idx, p_mech_new: new_p_mech_pu}
        %{state | events: [event | state.events]}
    end
  end

  defp default_xd_prime(gen) do
    case Map.get(gen, :fuel_type) do
      "NUC" -> 0.20
      "COL" -> 0.25
      ft when ft in ["NG", "OG", "DFO", "RFO", "PET"] -> 0.30
      ft when ft in ["WAT", "WH"] -> 0.35
      _ -> 0.30
    end
  end
end
