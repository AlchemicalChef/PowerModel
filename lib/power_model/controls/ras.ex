defmodule PowerModel.Controls.RAS do
  @moduledoc """
  Remedial Action Scheme (RAS).

  Pre-programmed protection logic that triggers specific corrective
  actions when predefined conditions are met. Also known as Special
  Protection Schemes (SPS) or System Integrity Protection Schemes
  (SIPS) in different jurisdictions.

  Each RAS definition consists of:
    * A **trigger** condition (e.g., a specific line trips, frequency
      drops below a threshold, or a combination of events)
    * One or more **actions** to execute (e.g., trip generators, shed
      load, open breakers, adjust setpoints)
    * A **delay** per action (accounts for communication and relay time)

  RAS definitions fire at most once (latching). Once triggered, a RAS
  will not re-trigger even if conditions persist or recur. This prevents
  oscillatory behavior from repeated activation.

  ## Trigger Types
    * `:line_trip` — fires when a specific transmission line trips
    * `:generator_trip` — fires when a specific generator trips
    * `:transformer_trip` — fires when a specific transformer trips
    * `:underfrequency` — fires when frequency drops below threshold
    * `:overvoltage` — fires when bus voltage exceeds threshold
    * `:undervoltage` — fires when bus voltage drops below threshold

  ## Action Types
    * `:trip_generator` — trip a specific generator
    * `:shed_load` — shed a fraction of load at specified buses
    * `:trip_line` — open a specific transmission line
    * `:adjust_hvdc` — change HVDC power order
    * `:run_back_generator` — reduce generator output to specified level
  """

  defstruct [
    :name,      # human-readable name
    :trigger,   # %{type: atom, component_id: integer, ...}
    :actions,   # [%{type: atom, target_id: integer, delay_s: float, ...}]
    :enabled,   # whether this RAS is armed
    :fired      # whether this RAS has already fired (latching)
  ]

  @doc """
  Initialize a list of RAS definitions from configuration maps.

  Each config map should have:
    * `:name` — descriptive name
    * `:trigger` — trigger specification map
    * `:actions` — list of action specification maps
    * `:enabled` — whether armed (default true)
  """
  def init(ras_configs) when is_list(ras_configs) do
    Enum.map(ras_configs, &init_one/1)
  end

  def init(ras_config) when is_map(ras_config) do
    init_one(ras_config)
  end

  defp init_one(config) do
    %__MODULE__{
      name: Map.get(config, :name, "unnamed"),
      trigger: Map.get(config, :trigger, %{}),
      actions: Map.get(config, :actions, []) |> Enum.map(&normalize_action/1),
      enabled: Map.get(config, :enabled, true),
      fired: false
    }
  end

  defp normalize_action(action) when is_map(action) do
    Map.merge(
      %{type: nil, target_id: nil, target_ids: nil, delay_s: 0.0, fraction: 1.0},
      action
    )
  end

  @doc """
  Check if any RAS triggers match the given events.

  Events should be a list of maps with at least `:component_type` and
  `:component_id` fields, matching the cascade event format. For
  frequency/voltage triggers, pass options:

    * `:frequency_hz` — current system frequency
    * `:bus_voltages` — map of bus_id => voltage_pu

  Returns `{updated_ras_list, triggered_actions}` where
  `triggered_actions` is a flat list of action maps from all newly
  triggered RAS definitions.
  """
  def check(ras_list, events, opts \\ []) when is_list(ras_list) do
    frequency_hz = Keyword.get(opts, :frequency_hz, 60.0)
    bus_voltages = Keyword.get(opts, :bus_voltages, %{})

    {updated_list, all_actions} =
      Enum.map_reduce(ras_list, [], fn ras, acc ->
        if ras.enabled and not ras.fired and trigger_matches?(ras.trigger, events, frequency_hz, bus_voltages) do
          fired_ras = %{ras | fired: true}
          actions_with_source = Enum.map(ras.actions, &Map.put(&1, :ras_name, ras.name))
          {fired_ras, acc ++ actions_with_source}
        else
          {ras, acc}
        end
      end)

    {updated_list, all_actions}
  end

  # --- Trigger matching ---

  defp trigger_matches?(%{type: :line_trip, component_id: id}, events, _freq, _voltages) do
    Enum.any?(events, fn e ->
      to_string(Map.get(e, :component_type)) == "transmission_line" and
        Map.get(e, :component_id) == id
    end)
  end

  defp trigger_matches?(%{type: :generator_trip, component_id: id}, events, _freq, _voltages) do
    Enum.any?(events, fn e ->
      to_string(Map.get(e, :component_type)) == "generator" and
        Map.get(e, :component_id) == id
    end)
  end

  defp trigger_matches?(%{type: :transformer_trip, component_id: id}, events, _freq, _voltages) do
    Enum.any?(events, fn e ->
      to_string(Map.get(e, :component_type)) == "transformer" and
        Map.get(e, :component_id) == id
    end)
  end

  defp trigger_matches?(%{type: :underfrequency, threshold_hz: threshold}, _events, freq, _voltages) do
    freq < threshold
  end

  defp trigger_matches?(%{type: :overvoltage, bus_id: bus_id, threshold_pu: threshold}, _events, _freq, voltages) do
    case Map.get(voltages, bus_id) do
      nil -> false
      v -> v > threshold
    end
  end

  defp trigger_matches?(%{type: :undervoltage, bus_id: bus_id, threshold_pu: threshold}, _events, _freq, voltages) do
    case Map.get(voltages, bus_id) do
      nil -> false
      v -> v < threshold
    end
  end

  defp trigger_matches?(_trigger, _events, _freq, _voltages), do: false
end
