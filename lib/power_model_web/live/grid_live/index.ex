defmodule PowerModelWeb.GridLive.Index do
  use PowerModelWeb, :live_view

  alias PowerModel.Engine.SimulationServer

  @impl true
  def mount(_params, _session, socket) do
    sim_id = "sim_#{:erlang.unique_integer([:positive])}"

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PowerModel.PubSub, "simulation:#{sim_id}")
    end

    socket = socket
    |> assign(:sim_id, sim_id)
    |> assign(:selected_component, nil)
    |> assign(:cascade_steps, [])
    |> assign(:cascade_active, false)
    |> assign(:system_metrics, %{
      total_gen_mw: 0.0,
      total_load_mw: 0.0,
      frequency_hz: 60.0,
      islands: 1,
      tripped_count: 0
    })
    |> assign(:solver_status, :idle)
    |> assign(:view_mode, "voltage_level")
    |> assign(:interconnection, "all")
    |> assign(:compensating_lines, [])
    |> assign(:last_dc_payload, nil)

    {:ok, socket, layout: {PowerModelWeb.Layouts, :grid}}
  end

  @impl true
  def handle_params(params, _url, socket) do
    interconnection = params["interconnection"] || "all"
    {:noreply, assign(socket, :interconnection, interconnection)}
  end

  @impl true
  def handle_event("select_component", %{"type" => type, "id" => id} = params, socket) do
    parsed_id = parse_int(id)

    component = %{
      type: type,
      id: parsed_id,
      capacity: parse_number(params["capacity"]),
      voltage_kv: parse_number(params["voltageKv"]),
      rating_mva: parse_number(params["ratingMva"]),
      fuel_type: fuel_type_name(parse_int(params["fuelType"])),
      facility_type: if(type == "critical_facility",
        do: params["facilityType"],
        else: water_facility_type_name(parse_int(params["facilityType"]))),
      category: critical_facility_category_name(parse_int(params["category"])),
      beds: parse_int(params["beds"]),
      trauma: params["trauma"],
      power_mw: parse_number(params["powerMw"]),
      bus_id: parse_int(params["busId"]),
      state: parse_int(params["state"]),
      data_source: resolve_data_source(type, parsed_id)
    }

    {:noreply, assign(socket, :selected_component, component)}
  end

  def handle_event("inject_failure", %{"type" => type, "id" => id}, socket)
      when type in ["transmission_line", "generator"] do
    sim_id = socket.assigns.sim_id
    component_id = String.to_integer(id)

    socket = socket
    |> assign(:cascade_active, true)
    |> assign(:solver_status, :solving)
    |> assign(:compensating_lines, [])

    ensure_sim_server(sim_id, socket.assigns.interconnection, {type, component_id})

    case type do
      "transmission_line" ->
        Task.Supervisor.start_child(PowerModel.TaskSupervisor, fn ->
          SimulationServer.trip_branch(sim_id, component_id)
        end)
      "generator" ->
        Task.Supervisor.start_child(PowerModel.TaskSupervisor, fn ->
          SimulationServer.trip_generator(sim_id, component_id)
        end)
    end

    {:noreply, socket}
  end

  def handle_event("inject_failure", _params, socket) do
    {:noreply, socket}
  end

  # --- Harmonic controls ---

  def handle_event("harmonic_source_type", %{"value" => type, "gen-id" => gen_id}, socket) do
    component = socket.assigns.selected_component

    if component && to_string(component.id) == gen_id do
      component = Map.merge(component, %{
        harmonic_type: type,
        thd_result: nil,
        ieee_519_compliant: nil
      })
      {:noreply, assign(socket, :selected_component, component)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("harmonic_adjust", %{"value" => value, "gen-id" => gen_id, "harmonic" => h}, socket) do
    component = socket.assigns.selected_component

    if component && to_string(component.id) == gen_id do
      key = String.to_atom("h#{h}_pct")
      {val, _} = Float.parse(value)
      component = Map.put(component, key, val)
      {:noreply, assign(socket, :selected_component, component)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("run_harmonics", %{"gen-id" => gen_id}, socket) do
    component = socket.assigns.selected_component

    if component && to_string(component.id) == gen_id do
      # Run harmonic analysis in a task to avoid blocking
      self_pid = self()
      Task.Supervisor.start_child(PowerModel.TaskSupervisor, fn ->
        result = run_harmonic_analysis(component)
        send(self_pid, {:harmonic_result, result})
      end)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("reset_simulation", _params, socket) do
    sim_id = socket.assigns.sim_id

    case Registry.lookup(PowerModel.SimulationRegistry, sim_id) do
      [{_pid, _}] -> SimulationServer.reset(sim_id)
      [] -> :ok
    end

    socket = socket
    |> assign(:cascade_steps, [])
    |> assign(:cascade_active, false)
    |> assign(:compensating_lines, [])
    |> assign(:last_dc_payload, nil)
    |> assign(:selected_component, nil)
    |> assign(:solver_status, :idle)
    |> push_event("reset_grid", %{})
    |> push_event("deselect_highlight", %{})

    {:noreply, socket}
  end

  def handle_event("change_view_mode", %{"mode" => mode}, socket) do
    socket = socket
    |> assign(:view_mode, mode)
    |> push_event("view_mode_changed", %{mode: mode})

    {:noreply, socket}
  end

  def handle_event("lookup_component", %{"type" => type, "component_id" => id_str}, socket) do
    trimmed = String.trim(id_str)
    if trimmed == "" do
      {:noreply, push_event(socket, "lookup_error", %{msg: "Enter an ID"})}
    else
      case Integer.parse(trimmed) do
        {id, _} ->
          case lookup_from_db(type, id) do
            nil ->
              {:noreply, push_event(socket, "lookup_error", %{msg: "#{humanize_lookup_type(type)} ##{id} not found"})}
            component ->
              socket = socket
              |> assign(:selected_component, component)
              |> push_event("highlight_component", %{type: type, id: id})
              |> push_event("fly_to_component", %{type: type, id: id})

              {:noreply, socket}
          end
        :error ->
          {:noreply, push_event(socket, "lookup_error", %{msg: "Invalid ID"})}
      end
    end
  end

  def handle_event("map_click", %{"lon" => _lon, "lat" => _lat}, socket) do
    {:noreply, socket}
  end

  def handle_event("viewport_changed", %{"zoom" => zoom, "bounds" => bounds}, socket) do
    {:noreply, push_event(socket, "update_lod", %{zoom: zoom, bounds: bounds})}
  end

  def handle_event("scrub_timeline", %{"step" => step}, socket) do
    step = String.to_integer(step)
    {:noreply, push_event(socket, "show_cascade_step", %{step: step})}
  end

  def handle_event("deselect", _params, socket) do
    socket = socket
    |> assign(:selected_component, nil)
    |> push_event("deselect_highlight", %{})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:simulation_dc_update, payload}, socket) do
    socket = socket
    |> assign(:solver_status, :dc_solved)
    |> assign(:compensating_lines, payload[:compensating_lines] || [])
    |> assign(:last_dc_payload, payload)
    |> update_metrics(payload)
    |> push_event("dc_results", payload)

    {:noreply, socket}
  end

  def handle_info({:simulation_ac_update, payload}, socket) do
    socket = socket
    |> assign(:solver_status, :ac_solved)
    |> update_metrics(payload)
    |> push_event("ac_results", payload)

    {:noreply, socket}
  end

  def handle_info({:simulation_cascade_step, payload}, socket) do
    steps = socket.assigns.cascade_steps ++ [payload]

    socket = socket
    |> assign(:cascade_steps, steps)
    |> push_event("cascade_step", payload)

    {:noreply, socket}
  end

  def handle_info({:simulation_cascade_done, payload}, socket) do
    cascade_steps = socket.assigns.cascade_steps
    dc = socket.assigns.last_dc_payload || %{}
    final_step = build_final_step(cascade_steps, dc)
    steps = cascade_steps ++ [final_step]

    socket = socket
    |> assign(:cascade_steps, steps)
    |> assign(:cascade_active, false)
    |> assign(:solver_status, :stable)
    |> update(:system_metrics, fn m ->
      %{m | tripped_count: payload.total_events}
    end)
    |> push_event("cascade_step", final_step)

    {:noreply, socket}
  end

  def handle_info({:simulation_reset, _payload}, socket) do
    socket = socket
    |> assign(:cascade_steps, [])
    |> assign(:cascade_active, false)
    |> assign(:last_dc_payload, nil)
    |> assign(:solver_status, :idle)
    |> assign(:system_metrics, %{
      total_gen_mw: 0.0, total_load_mw: 0.0,
      frequency_hz: 60.0, islands: 1, tripped_count: 0
    })

    {:noreply, socket}
  end

  def handle_info(:run_n1_screening, socket) do
    sim_id = socket.assigns.sim_id
    interconnection = socket.assigns.interconnection
    lv_pid = self()

    Task.Supervisor.start_child(PowerModel.TaskSupervisor, fn ->
      ensure_sim_server(sim_id, interconnection)

      case SimulationServer.get_state(sim_id) do
        %{has_dc_solution: true} = state ->
          violations = length(state.tripped_lines) + length(state.tripped_generators)
          send(lv_pid, {:n1_screening_done, violations})
        _ ->
          send(lv_pid, {:n1_screening_done, 0})
      end
    end)

    {:noreply, socket}
  end

  def handle_info({:n1_screening_done, violations}, socket) do
    send_update(PowerModelWeb.GridLive.FailureControls,
      id: "failure-controls",
      screening: false,
      violations: violations
    )
    {:noreply, socket}
  end

  def handle_info({:harmonic_result, result}, socket) do
    component = socket.assigns.selected_component

    if component do
      component = Map.merge(component, %{
        thd_result: result.thd,
        ieee_519_compliant: result.compliant
      })

      {:noreply, assign(socket, :selected_component, component)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp lookup_from_db("generator", id) do
    case PowerModel.Repo.get(PowerModel.Grid.Generator, id) do
      nil -> nil
      g ->
        %{
          type: "generator",
          id: g.id,
          capacity: g.p_max_mw,
          voltage_kv: nil,
          rating_mva: nil,
          fuel_type: g.fuel_type,
          facility_type: nil,
          power_mw: nil,
          bus_id: g.bus_id,
          state: 0,
          data_source: generator_source(g)
        }
    end
  end

  defp lookup_from_db("transmission_line", id) do
    case PowerModel.Repo.get(PowerModel.Grid.TransmissionLine, id) do
      nil -> nil
      tl ->
        %{
          type: "transmission_line",
          id: tl.id,
          capacity: nil,
          voltage_kv: tl.voltage_kv,
          rating_mva: tl.rating_a_mva,
          fuel_type: nil,
          facility_type: nil,
          power_mw: nil,
          bus_id: tl.from_bus_id,
          state: 0,
          data_source: line_source(tl)
        }
    end
  end

  defp lookup_from_db("substation", id) do
    case PowerModel.Repo.get(PowerModel.Grid.Substation, id) do
      nil -> nil
      s ->
        %{
          type: "substation",
          id: s.id,
          capacity: nil,
          voltage_kv: s.max_voltage_kv,
          rating_mva: nil,
          fuel_type: nil,
          facility_type: nil,
          power_mw: nil,
          bus_id: nil,
          state: 0,
          data_source: substation_source(s)
        }
    end
  end

  defp lookup_from_db("transformer", id) do
    case PowerModel.Repo.get(PowerModel.Grid.Transformer, id) do
      nil -> nil
      t ->
        %{
          type: "transformer",
          id: t.id,
          capacity: nil,
          voltage_kv: nil,
          rating_mva: t.rated_mva,
          fuel_type: nil,
          facility_type: nil,
          power_mw: nil,
          bus_id: t.from_bus_id,
          state: 0,
          data_source: "Estimated (multi-voltage substations)"
        }
    end
  end

  defp lookup_from_db("water_facility", id) do
    case PowerModel.Repo.get(PowerModel.Grid.WaterFacility, id) do
      nil -> nil
      w ->
        %{
          type: "water_facility",
          id: w.id,
          capacity: nil,
          voltage_kv: nil,
          rating_mva: nil,
          fuel_type: nil,
          facility_type: w.facility_type,
          power_mw: w.power_consumption_mw,
          bus_id: w.bus_id,
          state: 0,
          data_source: water_source(w)
        }
    end
  end

  defp lookup_from_db("critical_facility", id) do
    case PowerModel.Repo.get(PowerModel.Grid.CriticalFacility, id) do
      nil -> nil
      cf ->
        %{
          type: "critical_facility",
          id: cf.id,
          capacity: nil,
          voltage_kv: nil,
          rating_mva: nil,
          fuel_type: nil,
          facility_type: cf.facility_type,
          category: cf.category,
          beds: cf.beds,
          trauma: cf.trauma,
          address: cf.address,
          power_mw: cf.estimated_power_mw,
          bus_id: cf.bus_id,
          state: 0,
          data_source: critical_facility_source(cf)
        }
    end
  end

  defp lookup_from_db(_, _), do: nil

  defp resolve_data_source(type, id) when is_integer(id) do
    case type do
      "generator" ->
        case PowerModel.Repo.get(PowerModel.Grid.Generator, id) do
          nil -> nil
          g -> generator_source(g)
        end
      "transmission_line" ->
        case PowerModel.Repo.get(PowerModel.Grid.TransmissionLine, id) do
          nil -> nil
          tl -> line_source(tl)
        end
      "substation" ->
        case PowerModel.Repo.get(PowerModel.Grid.Substation, id) do
          nil -> nil
          s -> substation_source(s)
        end
      "transformer" -> "Estimated (multi-voltage substations)"
      "water_facility" ->
        case PowerModel.Repo.get(PowerModel.Grid.WaterFacility, id) do
          nil -> nil
          w -> water_source(w)
        end
      "critical_facility" ->
        case PowerModel.Repo.get(PowerModel.Grid.CriticalFacility, id) do
          nil -> nil
          cf -> critical_facility_source(cf)
        end
      _ -> nil
    end
  end
  defp resolve_data_source(_, _), do: nil

  defp run_harmonic_analysis(component) do
    alias PowerModel.Solver.Harmonics.{Sources, Solver, Impedance}

    gen_id = component.id
    bus_id = component[:bus_id]
    p_mw = component[:capacity] || 100.0
    harmonic_type = Map.get(component, :harmonic_type, "none")

    # Build custom spectrum from slider values
    custom_spectrum = %{
      5 => Map.get(component, :h5_pct, 0.0),
      7 => Map.get(component, :h7_pct, 0.0),
      11 => Map.get(component, :h11_pct, 0.0)
    }

    # Generate injection spectrum based on type
    base_spectrum = case harmonic_type do
      "six_pulse" -> Sources.six_pulse_spectrum(p_mw / 100.0)
      "twelve_pulse" -> Sources.twelve_pulse_spectrum(p_mw / 100.0)
      "pwm_inverter" -> Sources.pwm_inverter_spectrum(p_mw, 1.0, base_mva: 100.0)
      "arc_furnace" -> Sources.arc_furnace_spectrum(p_mw)
      _ -> %{}
    end

    # Override with slider values (convert pct to pu current)
    i_fund = p_mw / 100.0
    spectrum = Enum.reduce(custom_spectrum, base_spectrum, fn {h, pct}, acc ->
      if pct > 0.0 do
        mag = i_fund * pct / 100.0
        Map.put(acc, h, {mag, 0.0})
      else
        Map.delete(acc, h)
      end
    end)

    # Compute THD from the spectrum
    thd = if map_size(spectrum) > 0 do
      sum_sq = Enum.reduce(spectrum, 0.0, fn {_h, {mag, _}}, acc ->
        acc + mag * mag
      end)
      :math.sqrt(sum_sq) / max(i_fund, 0.001) * 100.0
    else
      0.0
    end

    # Check IEEE 519 compliance (simplified: THD < 5% for transmission)
    compliant = thd < 5.0

    %{thd: thd, compliant: compliant}
  end

  defp generator_source(g) do
    cond do
      g.eia_plant_id -> "EIA-860 (plant #{g.eia_plant_id})"
      g.fuel_type == "IMPORT" -> "Estimated (international tie)"
      true -> "EIA-860"
    end
  end

  defp line_source(tl) do
    case tl.source do
      "hifld_api" -> "HIFLD Transmission Lines"
      "international" -> "Estimated (international tie)"
      "synthetic" -> "Synthetic (model-generated)"
      s when is_binary(s) and s != "" -> s
      _ -> "HIFLD"
    end
  end

  defp substation_source(s) do
    cond do
      is_binary(s.hifld_id) and String.starts_with?(s.hifld_id, "osm_") ->
        "OpenStreetMap"
      is_binary(s.hifld_id) and String.starts_with?(s.hifld_id, "rutgers_") ->
        "HIFLD (Rutgers mirror)"
      is_binary(s.hifld_id) and s.hifld_id != "" ->
        "Derived from HIFLD lines"
      true ->
        "Derived (estimated)"
    end
  end

  defp water_source(w) do
    case w.source do
      s when is_binary(s) and s != "" -> s
      _ -> "San Diego County GIS"
    end
  end

  defp critical_facility_source(cf) do
    source_label = case cf.category do
      "hospital" -> "HIFLD Hospitals"
      "fire_station" -> "HIFLD Fire Stations"
      "police_station" -> "HIFLD Law Enforcement"
      "ems_station" -> "HIFLD EMS Stations"
      _ -> "HIFLD"
    end

    case cf.source do
      "hifld" -> source_label
      s when is_binary(s) and s != "" -> s
      _ -> source_label
    end
  end

  defp critical_facility_category_name(nil), do: nil
  defp critical_facility_category_name(1), do: "Hospital"
  defp critical_facility_category_name(2), do: "Fire Station"
  defp critical_facility_category_name(3), do: "Police Station"
  defp critical_facility_category_name(4), do: "EMS Station"
  defp critical_facility_category_name(_), do: nil

  defp humanize_lookup_type("transmission_line"), do: "Line"
  defp humanize_lookup_type("generator"), do: "Generator"
  defp humanize_lookup_type("substation"), do: "Substation"
  defp humanize_lookup_type("transformer"), do: "Transformer"
  defp humanize_lookup_type("water_facility"), do: "Water facility"
  defp humanize_lookup_type("critical_facility"), do: "Critical facility"
  defp humanize_lookup_type(t), do: t

  defp ensure_sim_server(sim_id, interconnection, component \\ nil) do
    case Registry.lookup(PowerModel.SimulationRegistry, sim_id) do
      [{_pid, _}] -> :ok
      [] ->
        interconnection_id = case interconnection do
          "all" -> resolve_interconnection(component)
          id -> String.to_integer(id)
        end

        opts = [sim_id: sim_id, interconnection_id: interconnection_id]

        case DynamicSupervisor.start_child(
          PowerModel.SimulationSupervisor,
          {SimulationServer, opts}
        ) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp resolve_interconnection({"transmission_line", line_id}) do
    import Ecto.Query
    PowerModel.Repo.one(
      from tl in PowerModel.Grid.TransmissionLine,
        join: b in PowerModel.Grid.Bus, on: tl.from_bus_id == b.id,
        where: tl.id == ^line_id,
        select: b.interconnection_id
    )
  end

  defp resolve_interconnection({"generator", gen_id}) do
    import Ecto.Query
    PowerModel.Repo.one(
      from g in PowerModel.Grid.Generator,
        join: b in PowerModel.Grid.Bus, on: g.bus_id == b.id,
        where: g.id == ^gen_id,
        select: b.interconnection_id
    )
  end

  defp resolve_interconnection(_), do: nil

  defp update_metrics(socket, payload) do
    update(socket, :system_metrics, fn m ->
      %{m |
        total_gen_mw: payload[:total_gen_mw] || m.total_gen_mw,
        total_load_mw: payload[:total_load_mw] || m.total_load_mw
      }
    end)
  end

  defp solver_status_class(:idle), do: "status-idle"
  defp solver_status_class(:solving), do: "status-solving"
  defp solver_status_class(:dc_solved), do: "status-dc"
  defp solver_status_class(:ac_solved), do: "status-ac"
  defp solver_status_class(:stable), do: "status-stable"
  defp solver_status_class(_), do: "status-idle"

  defp solver_status_text(:idle), do: "Idle"
  defp solver_status_text(:solving), do: "Solving..."
  defp solver_status_text(:dc_solved), do: "DC Solved"
  defp solver_status_text(:ac_solved), do: "AC Converged"
  defp solver_status_text(:stable), do: "Stable"
  defp solver_status_text(_), do: "Idle"

  defp fuel_type_name(nil), do: nil
  defp fuel_type_name(0), do: "Unknown"
  defp fuel_type_name(1), do: "Natural Gas"
  defp fuel_type_name(2), do: "Coal"
  defp fuel_type_name(3), do: "Coal"
  defp fuel_type_name(4), do: "Nuclear"
  defp fuel_type_name(5), do: "Hydro"
  defp fuel_type_name(6), do: "Wind"
  defp fuel_type_name(7), do: "Solar"
  defp fuel_type_name(_), do: "Other"

  defp water_facility_type_name(nil), do: nil
  defp water_facility_type_name(0), do: "Unknown"
  defp water_facility_type_name(1), do: "Desalination"
  defp water_facility_type_name(2), do: "Wastewater Treatment"
  defp water_facility_type_name(3), do: "Water Treatment"
  defp water_facility_type_name(4), do: "Pump Station"
  defp water_facility_type_name(5), do: "Reservoir"
  defp water_facility_type_name(6), do: "Pipeline"
  defp water_facility_type_name(_), do: "Other"

  defp parse_int(nil), do: nil
  defp parse_int(v) when is_integer(v), do: v
  defp parse_int(v) when is_float(v), do: round(v)
  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end
  defp parse_int(_), do: nil

  defp parse_number(nil), do: nil
  defp parse_number(v) when is_number(v), do: v * 1.0
  defp parse_number(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end
  defp parse_number(_), do: nil

  defp build_final_step(cascade_steps, dc_payload) do
    all_tripped_lines = cascade_steps
      |> Enum.flat_map(& &1[:tripped_line_ids] || [])
      |> Enum.uniq()

    all_tripped_gens = cascade_steps
      |> Enum.flat_map(& &1[:tripped_generator_ids] || [])
      |> Enum.uniq()

    all_shed = cascade_steps
      |> Enum.flat_map(& &1[:shed_ids] || [])
      |> Enum.uniq()

    all_water = cascade_steps
      |> Enum.flat_map(& &1[:water_facility_ids] || [])
      |> Enum.uniq()

    all_critical = cascade_steps
      |> Enum.flat_map(& &1[:critical_facility_ids] || [])
      |> Enum.uniq()

    last_step = List.last(cascade_steps) || %{step: 0, islands: 1}
    final_step_num = (last_step[:step] || 0) + 1

    %{
      step: final_step_num,
      is_final: true,
      trip_count: length(all_tripped_lines) + length(all_tripped_gens),
      islands: last_step[:islands] || 1,
      tripped_line_ids: all_tripped_lines,
      tripped_generator_ids: all_tripped_gens,
      overloaded_line_ids: dc_payload[:overloaded_line_ids] || [],
      stressed_line_ids: dc_payload[:stressed_line_ids] || [],
      rerouted_line_ids: dc_payload[:rerouted_line_ids] || [],
      shed_ids: all_shed,
      water_facility_ids: all_water,
      critical_facility_ids: all_critical,
      simulated_time: 0.0,
      trips: [],
      water_facility_trips: [],
      critical_facility_trips: []
    }
  end

  defp get_cascade_events(cascade_steps) do
    cascade_steps
    |> Enum.flat_map(fn step ->
      trips = step[:trips]
      trips = if is_list(trips), do: trips, else: []
      Enum.map(trips, fn trip ->
        Map.put(trip, :step, step[:step])
      end)
    end)
  end
end
