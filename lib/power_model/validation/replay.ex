defmodule PowerModel.Validation.Replay do
  @moduledoc """
  Executes deterministic validation cases against `PowerModel.Failure.Cascade`.
  """

  alias PowerModel.Failure.Cascade
  alias PowerModel.Validation.Case, as: ValidationCase

  @type replay_result :: %{
          case_id: String.t(),
          description: String.t(),
          actions: [term()],
          final_state: map(),
          step_results: [map()],
          metrics: map()
        }

  @doc """
  Run a validation case and return the full replay result + derived metrics.
  """
  @spec run_case(ValidationCase.t(), keyword()) :: replay_result()
  def run_case(%ValidationCase{} = validation_case, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, validation_case.base_mva)
    cascade_opts = validation_case.cascade_opts ++ Keyword.get(opts, :cascade_opts, [])

    initial_state = Cascade.init(validation_case.snapshot, base_mva, cascade_opts)

    {final_state, step_results} =
      Enum.reduce(validation_case.actions, {initial_state, []}, fn action,
                                                                   {state, collected_steps} ->
        {next_state, action_steps} = apply_action(state, action)
        {next_state, collected_steps ++ action_steps}
      end)

    metrics = compute_metrics(validation_case.snapshot, final_state, step_results)

    %{
      case_id: validation_case.id,
      description: validation_case.description,
      actions: validation_case.actions,
      final_state: final_state,
      step_results: step_results,
      metrics: metrics
    }
  end

  defp apply_action(state, :run_cascade), do: Cascade.run_cascade(state)
  defp apply_action(state, {:run_cascade}), do: Cascade.run_cascade(state)
  defp apply_action(state, {:trip_line, id}), do: Cascade.trip_line(state, id)
  defp apply_action(state, {:trip_generator, id}), do: Cascade.trip_generator(state, id)

  defp apply_action(state, {:trip_generators, ids}) when is_list(ids),
    do: Cascade.trip_generators(state, ids)

  defp apply_action(state, action) when is_map(action) do
    case action_type(action) do
      :run_cascade ->
        Cascade.run_cascade(state)

      :trip_line ->
        id = action_value(action, :id)
        Cascade.trip_line(state, id)

      :trip_generator ->
        id = action_value(action, :id)
        Cascade.trip_generator(state, id)

      :trip_generators ->
        ids = action_value(action, :ids)

        if is_list(ids) do
          Cascade.trip_generators(state, ids)
        else
          raise ArgumentError,
                "trip_generators action requires :ids list, got: #{inspect(action)}"
        end

      other ->
        raise ArgumentError, "unsupported replay action #{inspect(other)}: #{inspect(action)}"
    end
  end

  defp apply_action(_state, action) do
    raise ArgumentError, "unsupported replay action: #{inspect(action)}"
  end

  defp compute_metrics(initial_snapshot, final_state, step_results) do
    initial_load_by_id = Map.new(initial_snapshot.loads, &{&1.id, &1.p_mw})
    initial_total_load_mw = Enum.sum_by(initial_snapshot.loads, & &1.p_mw)
    final_total_load_mw = Enum.sum_by(final_state.loads, & &1.p_mw)
    event_counts = Enum.frequencies_by(final_state.events, & &1.failure_cause)

    %{
      stable: final_state.stable,
      cascade_steps: length(step_results),
      simulated_time_s: Map.get(final_state, :simulated_time, 0.0),
      line_trip_count: MapSet.size(final_state.tripped_lines || MapSet.new()),
      generator_trip_count: MapSet.size(final_state.tripped_generators || MapSet.new()),
      transformer_trip_count: MapSet.size(final_state.tripped_transformers || MapSet.new()),
      total_event_count: length(final_state.events),
      island_blackout_event_count: Map.get(event_counts, "island_blackout", 0),
      ufls_event_count: Map.get(event_counts, "ufls_shed", 0),
      governor_response_event_count: Map.get(event_counts, "governor_primary_response", 0),
      relay_81_event_count: Map.get(event_counts, "relay_81_uf", 0),
      frequency_excursion_event_count: Map.get(event_counts, "frequency_excursion", 0),
      out_of_step_event_count: Map.get(event_counts, "out_of_step", 0),
      transient_screen_event_count: Map.get(event_counts, "transient_screen", 0),
      initial_total_load_mw: initial_total_load_mw,
      final_total_load_mw: final_total_load_mw,
      load_shed_mw: max(initial_total_load_mw - final_total_load_mw, 0.0),
      blackout_load_mw: blackout_load_mw(final_state.events, initial_load_by_id),
      ufls_shed_mw: sum_event_field(final_state.events, "ufls_shed", :shed_mw),
      final_frequency_hz: Map.get(final_state, :frequency_hz, 60.0),
      min_frequency_hz: min_frequency_hz(final_state, step_results),
      transient_checks_run: Map.get(final_state, :transient_checks_run, 0),
      transient_unstable_checks: Map.get(final_state, :transient_unstable_checks, 0),
      transient_failed_checks: Map.get(final_state, :transient_failed_checks, 0),
      transient_last_stable: Map.get(final_state, :transient_last_stable),
      transient_last_oos_count: Map.get(final_state, :transient_last_oos_count, 0),
      transient_last_min_frequency_hz: Map.get(final_state, :transient_last_min_frequency_hz),
      transient_last_max_delta_deg: Map.get(final_state, :transient_last_max_delta_deg),
      cpf_result_present: not is_nil(final_state.cpf_result),
      cpf_converged: cpf_converged(final_state),
      voltage_margin_mw: Map.get(final_state, :voltage_margin_mw),
      critical_bus_id: Map.get(final_state, :critical_bus_id),
      small_signal_result_present: not is_nil(final_state.small_signal_result),
      small_signal_stable: Map.get(final_state, :small_signal_stable),
      stability_modes_count: length(final_state.stability_modes || []),
      harmonics_result_present: not is_nil(final_state.harmonics_result),
      harmonics_violations: Map.get(final_state, :harmonics_violations, 0) || 0,
      harmonics_worst_thd_pct: harmonics_worst_thd_pct(final_state),
      event_counts: event_counts
    }
  end

  defp blackout_load_mw(events, initial_load_by_id) do
    events
    |> Enum.filter(fn event ->
      event.failure_cause == "island_blackout" and event.component_type == "load"
    end)
    |> Enum.map(& &1.component_id)
    |> MapSet.new()
    |> Enum.reduce(0.0, fn load_id, acc ->
      acc + Map.get(initial_load_by_id, load_id, 0.0)
    end)
  end

  defp sum_event_field(events, cause, field) do
    events
    |> Enum.filter(&(&1.failure_cause == cause))
    |> Enum.reduce(0.0, fn event, acc ->
      acc + number_from_map(event.details || %{}, field)
    end)
  end

  defp min_frequency_hz(final_state, step_results) do
    values =
      [Map.get(final_state, :frequency_hz, 60.0)]
      |> Kernel.++(Enum.map(step_results, fn step -> Map.get(step, :frequency_hz, 60.0) end))
      |> Kernel.++(frequency_values_from_events(final_state.events))
      |> Enum.filter(&is_number/1)

    Enum.min(values, fn -> 60.0 end)
  end

  defp frequency_values_from_events(events) do
    Enum.flat_map(events, fn event ->
      details = Map.get(event, :details, %{})

      values =
        [
          optional_number_from_map(details, :nadir_hz),
          optional_number_from_map(details, :frequency_hz),
          optional_number_from_map(details, :min_frequency_hz)
        ]
        |> Enum.reject(&is_nil/1)

      values
    end)
  end

  defp harmonics_worst_thd_pct(final_state) do
    case Map.get(final_state, :harmonics_worst_thd) do
      %{thd_pct: thd_pct} when is_number(thd_pct) -> thd_pct
      _ -> 0.0
    end
  end

  defp cpf_converged(final_state) do
    case Map.get(final_state, :cpf_result) do
      %{converged: converged} when is_boolean(converged) -> converged
      _ -> nil
    end
  end

  defp action_type(action) do
    value = action_value(action, :type)

    case value do
      :run_cascade -> :run_cascade
      :trip_line -> :trip_line
      :trip_generator -> :trip_generator
      :trip_generators -> :trip_generators
      "run_cascade" -> :run_cascade
      "trip_line" -> :trip_line
      "trip_generator" -> :trip_generator
      "trip_generators" -> :trip_generators
      other -> other
    end
  end

  defp action_value(action, key) do
    Map.get(action, key) || Map.get(action, Atom.to_string(key))
  end

  defp number_from_map(map, key) when is_map(map) do
    value = Map.get(map, key) || Map.get(map, Atom.to_string(key))

    case value do
      number when is_number(number) -> number
      _ -> 0.0
    end
  end

  defp optional_number_from_map(map, key) when is_map(map) do
    value = Map.get(map, key) || Map.get(map, Atom.to_string(key))
    if is_number(value), do: value, else: nil
  end
end
