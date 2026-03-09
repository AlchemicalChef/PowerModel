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
          shed_fraction = config[:shed_fraction]
          total_load = Enum.sum(Enum.map(loads, & &1.p_mw))
          sim_fraction = if total_load > 0, do: sim_shed_mw / total_load, else: 0.0
          effective_fraction = max(shed_fraction, sim_fraction)

          apply_proportional_shedding(loads, effective_fraction, gen_mw, load_mw,
            frequency_nadir: nadir,
            gov_response_mw: trajectory |> List.last() |> Map.get(:gov_response_mw, 0.0)
          )
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
        shed_fraction = config[:shed_fraction]
        apply_proportional_shedding(loads, shed_fraction, gen_mw, load_mw)
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

        case Protection.uvls_action(vm_pu) do
          :none ->
            {load, events}

          {:shed, fraction} ->
            shed_mw = load.p_mw * fraction
            q_mvar = Map.get(load, :q_mvar) || 0.0

            updated = %{
              load
              | p_mw: load.p_mw - shed_mw,
                q_mvar: q_mvar * (1.0 - fraction)
            }

            event = %{
              component_type: "load",
              component_id: load.id,
              failure_cause: "uvls",
              details: %{
                bus_id: bus_id,
                vm_pu: vm_pu,
                shed_mw: shed_mw,
                shed_fraction: fraction,
                remaining_mw: updated.p_mw
              }
            }

            {updated, [event | events]}
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
      actual_shed_fraction = min(shed_fraction, deficit / total_load)

      extra_details =
        opts
        |> Keyword.take([:frequency_nadir, :gov_response_mw])
        |> Map.new()

      {updated_loads, shed_events} =
        Enum.map_reduce(loads, [], fn load, events ->
          shed_mw = load.p_mw * actual_shed_fraction

          updated = %{
            load
            | p_mw: load.p_mw - shed_mw,
              q_mvar: (load.q_mvar || 0.0) * (1.0 - actual_shed_fraction)
          }

          event = %{
            component_type: "load",
            component_id: load.id,
            failure_cause: "ufls_shed",
            details:
              Map.merge(extra_details, %{
                shed_mw: shed_mw,
                shed_fraction: actual_shed_fraction,
                remaining_mw: updated.p_mw
              })
          }

          {updated, [event | events]}
        end)

      {updated_loads, Enum.reverse(shed_events)}
    end
  end
end
