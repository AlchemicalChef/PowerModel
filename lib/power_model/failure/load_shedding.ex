defmodule PowerModel.Failure.LoadShedding do
  @moduledoc """
  Implements load shedding strategies for generation-load imbalance.

  Integrates with the swing-equation frequency simulator
  (`PowerModel.Solver.Frequency`) to determine shedding amounts based on
  the actual frequency trajectory rather than a static calculation.
  """

  alias PowerModel.Failure.Protection
  alias PowerModel.Solver.Frequency

  @doc """
  Apply UFLS load shedding to an island with generation deficit.

  When generator structs are available, uses the full frequency simulation
  to determine the frequency nadir and shed accordingly.  Falls back to
  the static `estimate_frequency` when only MW totals are provided.

  Returns `{updated_loads, shed_events}`.
  """
  def apply_ufls(loads, generators, gen_mw, load_mw)
      when is_list(generators) do
    if load_mw <= gen_mw do
      {loads, []}
    else
      lost_mw = load_mw - gen_mw
      trajectory = Frequency.simulate(generators, loads, lost_mw)
      nadir = Frequency.nadir(trajectory)
      schedule = Protection.ufls_schedule(nadir)

      sim_shed_mw = trajectory |> List.last() |> Map.get(:load_shed_mw, 0.0)

      case schedule do
        [] ->
          {loads, []}

        config ->
          stage = config[:stage] || 0
          shed_fraction = config[:shed_fraction]
          total_load = Enum.sum(Enum.map(loads, & &1.p_mw))
          sim_fraction = if total_load > 0, do: sim_shed_mw / total_load, else: 0.0
          target_fraction = max(shed_fraction, sim_fraction)
          current_fraction = current_ufls_fraction(loads)
          incremental_fraction = max(target_fraction - current_fraction, 0.0)

          if incremental_fraction <= 0.0 do
            {loads, []}
          else
            apply_proportional_shedding(loads, incremental_fraction, gen_mw, load_mw,
              stage: stage,
              cumulative_fraction: min(current_fraction + incremental_fraction, 1.0),
              frequency_nadir: nadir,
              gov_response_mw: trajectory |> List.last() |> Map.get(:gov_response_mw, 0.0)
            )
          end
      end
    end
  end

  def apply_ufls(loads, gen_mw, load_mw) do
    freq = Protection.estimate_frequency(gen_mw, load_mw)
    schedule = Protection.ufls_schedule(freq)

    case schedule do
      [] ->
        {loads, []}

      config ->
        stage = config[:stage] || 0
        shed_fraction = config[:shed_fraction]
        current_fraction = current_ufls_fraction(loads)
        incremental_fraction = max(shed_fraction - current_fraction, 0.0)

        if incremental_fraction <= 0.0 do
          {loads, []}
        else
          apply_proportional_shedding(loads, incremental_fraction, gen_mw, load_mw,
            stage: stage,
            cumulative_fraction: min(current_fraction + incremental_fraction, 1.0)
          )
        end
    end
  end

  @doc """
  Apply Under-Voltage Load Shedding (UVLS) to loads based on bus voltages.

  For each load, looks up the voltage at its bus (via `bus_voltages`, a map
  of bus_id => vm_pu).  When the voltage is below a UVLS threshold, the
  load's `p_mw` and `q_mvar` are reduced by the staged shed percentage
  determined by `Protection.uvls_action/1`.

  Returns `{updated_loads, shed_events}` where each shed event is a map
  compatible with the cascade event format.
  """
  def apply_uvls(loads, bus_voltages) when is_map(bus_voltages) do
    {updated_loads, shed_events} =
      Enum.map_reduce(loads, [], fn load, events ->
        bus_id = Map.get(load, :bus_id)
        vm_pu = Map.get(bus_voltages, bus_id, 1.0)
        {target_stage, target_fraction} = uvls_stage_for_voltage(vm_pu)
        current_stage = Map.get(load, :uvls_stage, 0)
        current_fraction = uvls_stage_fraction(current_stage)

        if target_stage <= current_stage do
          {load, events}
        else
          increment_fraction = max(target_fraction - current_fraction, 0.0)

          if increment_fraction <= 0.0 do
            {load, events}
          else
            shed_mw = load.p_mw * increment_fraction
            q_mvar = Map.get(load, :q_mvar) || 0.0

            updated =
              Map.merge(load, %{
                p_mw: load.p_mw - shed_mw,
                q_mvar: q_mvar * (1.0 - increment_fraction),
                uvls_stage: target_stage,
                uvls_cumulative_fraction: target_fraction
              })

            event = %{
              component_type: "load",
              component_id: load.id,
              failure_cause: "uvls",
              details: %{
                bus_id: bus_id,
                vm_pu: vm_pu,
                stage: target_stage,
                shed_mw: shed_mw,
                shed_fraction: increment_fraction,
                cumulative_fraction: target_fraction,
                remaining_mw: updated.p_mw
              }
            }

            {updated, [event | events]}
          end
        end
      end)

    {updated_loads, Enum.reverse(shed_events)}
  end

  @doc """
  Proportional load shedding: reduce all loads by a fraction
  until generation-load balance is restored.

  Accepts optional keyword metadata (e.g., frequency_nadir, gov_response_mw)
  that will be included in the shed event details.
  """
  def apply_proportional_shedding(loads, shed_fraction, gen_mw, load_mw, opts \\ []) do
    deficit = load_mw - gen_mw

    if deficit <= 0 do
      {loads, []}
    else
      total_load = Enum.sum(Enum.map(loads, & &1.p_mw))
      target_shed_mw = min(total_load * shed_fraction, deficit)

      extra_details =
        opts
        |> Keyword.take([:frequency_nadir, :gov_response_mw, :stage, :cumulative_fraction])
        |> Map.new()

      ordered_loads = Enum.sort_by(loads, &load_shed_priority_rank/1)

      {updated_by_id, shed_events, _remaining} =
        Enum.reduce(ordered_loads, {%{}, [], target_shed_mw}, fn load, {acc, events, rem_mw} ->
          if rem_mw <= 0.0 do
            {Map.put(acc, load.id, load), events, rem_mw}
          else
            shed_mw = min(load.p_mw, rem_mw)
            base_mw = max(load.p_mw, 1.0e-6)
            load_fraction = shed_mw / base_mw
            previous_cumulative = Map.get(load, :ufls_cumulative_fraction, 0.0)
            new_cumulative = min(previous_cumulative + load_fraction, 1.0)

            updated =
              load
              |> Map.put(:p_mw, load.p_mw - shed_mw)
              |> Map.put(:q_mvar, (load.q_mvar || 0.0) * (1.0 - load_fraction))
              |> Map.put(:ufls_cumulative_fraction, new_cumulative)
              |> maybe_put_ufls_stage(opts)

            event = %{
              component_type: "load",
              component_id: load.id,
              failure_cause: "ufls_shed",
              details:
                Map.merge(extra_details, %{
                  shed_mw: shed_mw,
                  shed_fraction: load_fraction,
                  remaining_mw: updated.p_mw,
                  shed_priority: load_shed_priority_label(load)
                })
            }

            {Map.put(acc, load.id, updated), [event | events], rem_mw - shed_mw}
          end
        end)

      updated_loads = Enum.map(loads, fn load -> Map.get(updated_by_id, load.id, load) end)
      {updated_loads, Enum.reverse(shed_events)}
    end
  end

  defp current_ufls_fraction(loads) do
    loads
    |> Enum.map(&Map.get(&1, :ufls_cumulative_fraction, 0.0))
    |> Enum.max(fn -> 0.0 end)
  end

  defp maybe_put_ufls_stage(load, opts) do
    case Keyword.get(opts, :stage) do
      stage when is_integer(stage) and stage > 0 ->
        current = Map.get(load, :ufls_stage, 0)
        Map.put(load, :ufls_stage, max(current, stage))

      _ ->
        load
    end
  end

  defp load_shed_priority_rank(load) do
    cond do
      Map.get(load, :critical, false) -> 100
      (Map.get(load, :shed_priority) || Map.get(load, "shed_priority")) in [:high, "high"] -> 80
      (Map.get(load, :shed_priority) || Map.get(load, "shed_priority")) in [:low, "low"] -> 20
      is_number(Map.get(load, :shed_priority)) -> trunc(Map.get(load, :shed_priority))
      true -> 50
    end
  end

  defp load_shed_priority_label(load) do
    cond do
      Map.get(load, :critical, false) ->
        "critical"

      (Map.get(load, :shed_priority) || Map.get(load, "shed_priority")) in [:high, "high"] ->
        "high"

      (Map.get(load, :shed_priority) || Map.get(load, "shed_priority")) in [:low, "low"] ->
        "low"

      true ->
        "normal"
    end
  end

  defp uvls_stage_for_voltage(vm_pu) do
    cond do
      vm_pu < 0.80 -> {3, 0.15}
      vm_pu < 0.85 -> {2, 0.10}
      vm_pu < 0.90 -> {1, 0.05}
      true -> {0, 0.0}
    end
  end

  defp uvls_stage_fraction(0), do: 0.0
  defp uvls_stage_fraction(1), do: 0.05
  defp uvls_stage_fraction(2), do: 0.10
  defp uvls_stage_fraction(3), do: 0.15
  defp uvls_stage_fraction(_), do: 0.15
end
