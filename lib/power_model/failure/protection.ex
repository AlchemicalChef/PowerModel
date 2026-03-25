defmodule PowerModel.Failure.Protection do
  @moduledoc """
  Protection system models for cascade simulation.
  Implements overcurrent, undervoltage, underfrequency, and Zone 3 distance relays.
  """

  @zone3_loading_min 80.0
  @zone3_loading_range 40.0
  @zone3_voltage_threshold 0.9
  @zone3_voltage_range 0.15
  @zone3_trip_threshold 0.5

  @default_undervoltage 0.85
  @default_overvoltage 1.15

  @uvls_stage1_pu 0.90
  @uvls_stage2_pu 0.85
  @uvls_stage3_pu 0.80

  # NERC PRC-006 aligned UFLS stages: {threshold_hz, stage, cumulative_shed_fraction}
  @ufls_stages [
    {58.0, 4, 0.35},
    {58.5, 3, 0.30},
    {59.0, 2, 0.20},
    {59.5, 1, 0.10}
  ]

  # Conductor thermal time constants by voltage class (seconds).
  # Represents time for conductor to reach thermal limit from rated temperature.
  @thermal_tau %{
    69  => 600.0,
    115 => 900.0,
    138 => 900.0,
    230 => 1200.0,
    345 => 1500.0,
    500 => 1800.0,
    765 => 1800.0
  }

  # Generator underfrequency relay 81 settings by fuel category
  @uf_relay %{
    "nuclear" => 59.0,
    "coal"    => 58.0,
    "gas"     => 57.5,
    "hydro"   => 57.0,
    "wind"    => 57.5,
    "solar"   => 57.5
  }

  @doc """
  Check thermal overloads and return components to trip.
  Uses inverse-time characteristic: t_trip = k / (I/I_rated - 1)
  For simulation, we trip immediately if loading > 100%.

  Loading is computed from apparent power S = sqrt(P^2 + Q^2) when reactive
  power (`q_flow_mvar`) is available in the flow map (AC solutions).  For DC
  solutions where only `p_flow_mw` is present, loading falls back to |P|/rating.
  """
  def check_thermal_overloads(line_flows, threshold_pct \\ 100.0) do
    line_flows
    |> Enum.map(fn {key, flow} -> {key, recompute_loading(flow)} end)
    |> Enum.filter(fn {_key, flow} ->
      flow.loading_pct > threshold_pct
    end)
    |> Enum.map(fn {{type, id}, flow} ->
      %{
        component_type: component_type_string(type),
        component_id: id,
        failure_cause: "thermal_overload",
        details: %{
          loading_pct: flow.loading_pct,
          p_flow_mw: flow.p_flow_mw,
          s_flow_mva: Map.get(flow, :s_flow_mva)
        }
      }
    end)
    |> Enum.sort_by(fn trip -> -trip.details.loading_pct end)
  end

  defp recompute_loading(%{q_flow_mvar: q, p_flow_mw: p} = flow) when is_number(q) do
    s_mva = :math.sqrt(p * p + q * q)
    rating = rating_from_flow(flow)

    if rating > 0 do
      %{flow | loading_pct: s_mva / rating * 100.0, s_flow_mva: s_mva}
    else
      flow
    end
  end
  defp recompute_loading(flow), do: flow

  defp rating_from_flow(%{rating_a_mva: r}) when is_number(r) and r > 0, do: r
  defp rating_from_flow(%{rated_mva: r}) when is_number(r) and r > 0, do: r
  defp rating_from_flow(%{loading_pct: pct, p_flow_mw: p}) when pct > 0 do
    abs(p) / (pct / 100.0)
  end
  defp rating_from_flow(_), do: 0

  @doc """
  Zone 3 distance relay check for load encroachment.

  In stressed conditions a heavily-loaded line can present an apparent impedance
  that falls inside the Zone 3 relay circle, causing the relay to misoperate
  (trip a healthy but overloaded line).

  Simplified model (usable without full AC state):
    - A line is at Zone 3 risk when loading_pct > 80% AND the voltage at either
      end is below 0.9 pu.
    - Trip probability increases with loading and decreases with voltage.
    - Returns trips with `failure_cause: "zone3_relay"`.

  Parameters
    - `line_flows` — the `solution.line_flows` map
    - `lines`      — list of line/transformer maps (need `from_bus_id`, `to_bus_id`)
    - `buses`      — list of bus maps (need `id`, `base_kv`)
    - `vm_pu`      — list of per-unit voltage magnitudes (same order as `bus_ids`)
    - `va_rad`     — list of voltage angles in radians (same order as `bus_ids`)
    - `bus_index`  — map of bus_id => positional index into vm_pu / va_rad lists
  """
  def check_zone3_encroachment(line_flows, lines, _buses, vm_pu, _va_rad, bus_index) do
    line_map = Map.new(lines, fn l -> {l.id, l} end)

    line_flows
    |> Enum.filter(fn {{_type, _id}, flow} -> flow.loading_pct > @zone3_loading_min end)
    |> Enum.filter(fn {{type, id}, _flow} ->
      component = case type do
        :line -> Map.get(line_map, id)
        :transformer -> Map.get(line_map, id)
        _ -> nil
      end

      if component do
        from_idx = Map.get(bus_index, component.from_bus_id)
        to_idx = Map.get(bus_index, component.to_bus_id)

        v_from = if from_idx, do: Enum.at(vm_pu, from_idx, 1.0), else: 1.0
        v_to = if to_idx, do: Enum.at(vm_pu, to_idx, 1.0), else: 1.0

        v_from < @zone3_voltage_threshold or v_to < @zone3_voltage_threshold
      else
        false
      end
    end)
    |> Enum.map(fn {{type, id}, flow} ->
      component = Map.get(line_map, id)
      from_idx = if component, do: Map.get(bus_index, component.from_bus_id), else: nil
      to_idx = if component, do: Map.get(bus_index, component.to_bus_id), else: nil
      v_from = if from_idx, do: Enum.at(vm_pu, from_idx, 1.0), else: 1.0
      v_to = if to_idx, do: Enum.at(vm_pu, to_idx, 1.0), else: 1.0

      v_min = min(v_from, v_to)
      trip_probability = zone3_trip_probability(flow.loading_pct, v_min)

      %{
        component_type: component_type_string(type),
        component_id: id,
        failure_cause: "zone3_relay",
        details: %{
          loading_pct: flow.loading_pct,
          p_flow_mw: flow.p_flow_mw,
          v_from_pu: v_from,
          v_to_pu: v_to,
          trip_probability: trip_probability
        }
      }
    end)
    |> Enum.filter(fn trip -> trip.details.trip_probability > @zone3_trip_threshold end)
    |> Enum.sort_by(fn trip -> -trip.details.trip_probability end)
  end

  @doc """
  Compute Zone 3 misoperation probability.

  The probability rises with loading percentage (above 80%) and with voltage
  depression (below 0.9 pu).  At 100% loading and 0.8 pu voltage the
  probability is ~0.80; at 120% loading and 0.75 pu it saturates near 1.0.
  """
  def zone3_trip_probability(loading_pct, v_min_pu) do
    loading_factor = min(max((loading_pct - @zone3_loading_min) / @zone3_loading_range, 0.0), 1.0)
    voltage_factor = min(max((@zone3_voltage_threshold - v_min_pu) / @zone3_voltage_range, 0.0), 1.0)
    loading_factor * voltage_factor
  end

  @doc """
  Check voltage violations and return buses with issues.
  Under-voltage relay trips at V < 0.85 pu.
  Over-voltage trips at V > 1.15 pu.
  """
  def check_voltage_violations(bus_ids, vm_pu, opts \\ []) do
    uv_threshold = Keyword.get(opts, :undervoltage, @default_undervoltage)
    ov_threshold = Keyword.get(opts, :overvoltage, @default_overvoltage)

    Enum.zip(bus_ids, vm_pu)
    |> Enum.filter(fn {_id, v} -> v < uv_threshold or v > ov_threshold end)
    |> Enum.map(fn {bus_id, v} ->
      cause = if v < uv_threshold, do: "undervoltage", else: "overvoltage"
      %{
        component_type: "bus",
        component_id: bus_id,
        failure_cause: cause,
        details: %{vm_pu: v}
      }
    end)
  end

  @doc """
  Under-Frequency Load Shedding (UFLS) scheme.
  Sheds load in stages based on frequency deviation.
  Returns list of {bus_id, shed_fraction} tuples.
  """
  def ufls_schedule(frequency_hz) do
    case Enum.find(@ufls_stages, fn {threshold, _stage, _frac} -> frequency_hz < threshold end) do
      nil -> []
      {_threshold, stage, shed_fraction} -> [stage: stage, shed_fraction: shed_fraction]
    end
  end

  @doc """
  Estimate system frequency based on generation-load imbalance.

  When called with generator and load structs, delegates to the swing-equation
  frequency simulator (`PowerModel.Solver.Frequency`) and returns the nadir
  (minimum) frequency.  When called with simple MW values (backward-compatible
  2-arity form), uses a quick steady-state droop estimate.
  """
  def estimate_frequency(generators, loads, gen_mw, load_mw)
      when is_list(generators) and is_list(loads) do
    if load_mw <= 0.0 do
      60.0
    else
      lost_mw = load_mw - gen_mw
      trajectory = PowerModel.Solver.Frequency.simulate(generators, loads, lost_mw)
      PowerModel.Solver.Frequency.nadir(trajectory)
    end
  end

  def estimate_frequency(gen_mw, load_mw, base_freq \\ 60.0) do
    if load_mw <= 0.0 do
      base_freq
    else
      imbalance_fraction = (gen_mw - load_mw) / load_mw
      base_freq * (1.0 + imbalance_fraction * 0.05)
    end
  end

  defp component_type_string(:line), do: "transmission_line"
  defp component_type_string(:transformer), do: "transformer"
  defp component_type_string(other), do: Atom.to_string(other)

  @doc """
  Under-Voltage Load Shedding (UVLS) action for a given bus voltage.

  Returns `{:shed, percentage}` indicating the fraction of load to shed,
  or `:none` if no shedding is needed.  Stages mirror typical utility UVLS
  relay settings:

    * V < 0.80 pu -- shed 15% (immediate, last resort)
    * V < 0.85 pu -- shed 10%
    * V < 0.90 pu -- shed 5%
    * V >= 0.90   -- no action
  """
  def uvls_action(vm_pu) do
    cond do
      vm_pu < @uvls_stage3_pu -> {:shed, 0.15}
      vm_pu < @uvls_stage2_pu -> {:shed, 0.10}
      vm_pu < @uvls_stage1_pu -> {:shed, 0.05}
      true -> :none
    end
  end

  @doc """
  Conductor thermal trip time using thermal model.

  Uses `t = tau * ln((I^2 - 1) / (I^2 - I_max^2))` where I is the current
  ratio (loading_pct/100), I_max is the emergency rating ratio, and tau is
  the conductor thermal time constant.

  When loading exceeds the emergency rating, trips on protection relay (~0.5s).
  When loading is between Rate A and the emergency rating, the conductor heats
  slowly and may survive for minutes.

  ## Options
    * `:voltage_kv` — line voltage class for thermal tau lookup
    * `:rating_a_mva` — normal continuous rating
    * `:rating_b_mva` — 30-minute emergency rating
    * `:rating_c_mva` — 5-minute emergency rating
  """
  def overcurrent_trip_time(loading_pct, opts \\ [])

  def overcurrent_trip_time(loading_pct, opts) when is_list(opts) do
    if loading_pct <= 100.0 do
      :infinity
    else
      voltage_kv = Keyword.get(opts, :voltage_kv)
      rating_a = Keyword.get(opts, :rating_a_mva)
      rating_c = Keyword.get(opts, :rating_c_mva)

      # Emergency ratio: Rate C / Rate A (default 1.5x)
      i_max = if rating_a && rating_a > 0 && rating_c && rating_c > 0 do
        rating_c / rating_a
      else
        1.5
      end

      i = loading_pct / 100.0
      i_sq = i * i
      i_max_sq = i_max * i_max

      # Determine emergency rating ratio for Rate B (30 min) tier
      rating_b = Keyword.get(opts, :rating_b_mva)
      i_rate_b = if rating_a && rating_a > 0 && rating_b && rating_b > 0 do
        rating_b / rating_a
      else
        1.2
      end

      cond do
        i_sq >= i_max_sq ->
          # Exceeds Rate C — fast relay trip
          0.5

        i >= i_rate_b ->
          # Between Rate B and Rate C — trip after Rate C time limit (5 min = 300s)
          300.0

        i > 1.0 ->
          # Between Rate A and Rate B — trip after Rate B time limit (30 min = 1800s)
          1800.0

        true ->
          :infinity
      end
    end
  end

  # Backward-compatible 2-arity with numeric k (legacy callers)
  def overcurrent_trip_time(loading_pct, k) when is_number(k) do
    if loading_pct <= 100.0 do
      :infinity
    else
      ratio = loading_pct / 100.0
      k / (ratio - 1.0)
    end
  end

  @doc """
  Effective rating for a line given how long the overload has persisted.

  * < 30s: use Rate C (short-term emergency, default 1.5 * Rate A)
  * < 30 min: use Rate B (emergency, default 1.2 * Rate A)
  * otherwise: use Rate A (normal continuous)
  """
  def effective_rating(line, elapsed_s \\ 0.0) do
    rate_a = Map.get(line, :rating_a_mva) || 0.0

    cond do
      elapsed_s < 30.0 ->
        Map.get(line, :rating_c_mva) || rate_a * 1.5
      elapsed_s < 1800.0 ->
        Map.get(line, :rating_b_mva) || rate_a * 1.2
      true ->
        rate_a
    end
  end

  @doc """
  Check generator protection relays (Relay 81 underfrequency).

  Returns a list of generator trip events for generators whose protection
  relays would operate at the given system frequency.
  """
  def check_generator_relays(generators, frequency_hz) do
    if frequency_hz >= 59.5 do
      # No generator relays fire above 59.5 Hz
      []
    else
      Enum.flat_map(generators, fn gen ->
        fuel = normalize_gen_fuel(Map.get(gen, :fuel_type))
        trip_hz = Map.get(@uf_relay, fuel, 57.5)

        if frequency_hz < trip_hz do
          [%{
            component_type: "generator",
            component_id: gen.id,
            failure_cause: "relay_81_uf",
            details: %{
              frequency_hz: frequency_hz,
              trip_setpoint_hz: trip_hz,
              fuel_type: fuel,
              p_mw: gen.p_max_mw
            },
            trip_time_s: 0.5
          }]
        else
          []
        end
      end)
    end
  end

  defp thermal_tau_for_kv(nil), do: 900.0
  defp thermal_tau_for_kv(kv) do
    # Find closest voltage class
    {_best_kv, tau} =
      @thermal_tau
      |> Enum.min_by(fn {v, _tau} -> abs(v - kv) end)

    tau
  end

  defp normalize_gen_fuel(nil), do: "gas"
  defp normalize_gen_fuel(fuel) when is_binary(fuel) do
    f = String.downcase(fuel)
    cond do
      f in ["nuc", "nuclear"] -> "nuclear"
      f in ["col", "coal", "bit", "sub", "lig"] -> "coal"
      f in ["ng", "gas", "og", "dfo", "rfo", "pet"] -> "gas"
      f in ["wat", "wh", "hydro"] -> "hydro"
      f in ["wnd", "wind"] -> "wind"
      f in ["sun", "solar"] -> "solar"
      true -> "gas"
    end
  end
end
