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

  @ufls_stages [
    {58.0, 4, 0.55},
    {58.5, 3, 0.30},
    {59.0, 2, 0.15},
    {59.5, 1, 0.05}
  ]

  @overcurrent_k 0.14

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
  Inverse-time overcurrent trip time.
  Returns time in seconds for a given loading percentage.
  """
  def overcurrent_trip_time(loading_pct, k \\ @overcurrent_k) do
    if loading_pct <= 100.0 do
      :infinity
    else
      ratio = loading_pct / 100.0
      k / (ratio - 1.0)
    end
  end
end
