defmodule PowerModel.Failure.Protection do
  @moduledoc """
  Protection system models for cascade simulation.
  Implements overcurrent, undervoltage, underfrequency, and Zone 3 distance relays.
  """

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

  # Recompute loading_pct using apparent power when Q is available.
  # For DC solutions (no q_flow_mvar key), the original loading_pct is kept.
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

  # Extract the line/transformer rating from the flow map or fall back to
  # back-computing it from the original loading_pct and p_flow_mw.
  defp rating_from_flow(%{rating_mva: r}) when is_number(r) and r > 0, do: r
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
    # Build a quick lookup: line/xfmr id => struct
    line_map = Map.new(lines, fn l -> {l.id, l} end)

    line_flows
    |> Enum.filter(fn {{_type, _id}, flow} -> flow.loading_pct > 80.0 end)
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

        # Zone 3 encroachment when either end voltage is depressed
        v_from < 0.9 or v_to < 0.9
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

      # Trip probability: higher loading + lower voltage => more likely
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
    # Only trip lines where probability exceeds 50%
    |> Enum.filter(fn trip -> trip.details.trip_probability > 0.5 end)
    |> Enum.sort_by(fn trip -> -trip.details.trip_probability end)
  end

  @doc """
  Compute Zone 3 misoperation probability.

  The probability rises with loading percentage (above 80%) and with voltage
  depression (below 0.9 pu).  At 100% loading and 0.8 pu voltage the
  probability is ~0.80; at 120% loading and 0.75 pu it saturates near 1.0.
  """
  def zone3_trip_probability(loading_pct, v_min_pu) do
    # Loading factor: 0 at 80%, 1.0 at 120%
    loading_factor = min(max((loading_pct - 80.0) / 40.0, 0.0), 1.0)
    # Voltage factor: 0 at 0.9 pu, 1.0 at 0.75 pu
    voltage_factor = min(max((0.9 - v_min_pu) / 0.15, 0.0), 1.0)
    # Combined probability (both conditions must be present)
    loading_factor * voltage_factor
  end

  @doc """
  Check voltage violations and return buses with issues.
  Under-voltage relay trips at V < 0.85 pu.
  Over-voltage trips at V > 1.15 pu.
  """
  def check_voltage_violations(bus_ids, vm_pu, opts \\ []) do
    uv_threshold = Keyword.get(opts, :undervoltage, 0.85)
    ov_threshold = Keyword.get(opts, :overvoltage, 1.15)

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
    cond do
      frequency_hz >= 59.5 -> []
      frequency_hz >= 59.0 -> [stage: 1, shed_fraction: 0.05]
      frequency_hz >= 58.5 -> [stage: 2, shed_fraction: 0.10]
      frequency_hz >= 58.0 -> [stage: 3, shed_fraction: 0.15]
      true -> [stage: 4, shed_fraction: 0.25]
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
      # Steady-state frequency droop: 5% droop characteristic
      base_freq * (1.0 + imbalance_fraction * 0.05)
    end
  end

  defp component_type_string(:line), do: "transmission_line"
  defp component_type_string(:transformer), do: "transformer"
  defp component_type_string(other), do: Atom.to_string(other)

  @doc """
  Inverse-time overcurrent trip time.
  Returns time in seconds for a given loading percentage.
  """
  def overcurrent_trip_time(loading_pct, k \\ 0.14) do
    if loading_pct <= 100.0 do
      :infinity
    else
      ratio = loading_pct / 100.0
      k / (ratio - 1.0)
    end
  end
end
