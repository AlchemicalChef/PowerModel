defmodule PowerModelWeb.GridLive.Index do
  use PowerModelWeb, :live_view

  alias PowerModel.Grid
  alias PowerModel.Engine.SimulationServer
  alias PowerModel.Validation.{Case, Harness}
  alias PowerModel.Solver.Harmonics.Sources
  alias PowerModel.Solver.Harmonics.Scenario, as: HarmonicsScenario
  alias PowerModel.Solver.Harmonics.Scenario.HarmonicDevice
  alias PowerModel.Solver.Harmonics.Scenario.HarmonicScenario

  @impl true
  def mount(_params, _session, socket) do
    sim_id = "sim_#{:erlang.unique_integer([:positive])}"
    validation_cases = validation_cases()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PowerModel.PubSub, "simulation:#{sim_id}")
    end

    socket =
      socket
      |> assign(:sim_id, sim_id)
      |> assign(:selected_component, nil)
      |> assign(:cascade_steps, [])
      |> assign(:cascade_active, false)
      |> assign(:system_metrics, default_system_metrics())
      |> assign(:solver_status, :idle)
      |> assign(:view_mode, "voltage_level")
      |> assign(:simulation_hour, nil)
      |> assign(:interconnection, "all")
      |> assign(:compensating_lines, [])
      |> assign(:last_dc_payload, nil)
      |> assign(:model_options, default_model_options())
      |> assign(:analysis_results, nil)
      |> assign(:validation_cases, validation_cases)
      |> assign(:selected_validation_case_id, default_validation_case_id(validation_cases))
      |> assign(:validation_running, false)
      |> assign(:validation_report, nil)

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
      facility_type:
        if(type == "critical_facility",
          do: params["facilityType"],
          else: water_facility_type_name(parse_int(params["facilityType"]))
        ),
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

    socket =
      socket
      |> assign(:cascade_active, true)
      |> assign(:solver_status, :solving)
      |> assign(:compensating_lines, [])
      |> assign(:analysis_results, nil)

    ensure_sim_server(
      sim_id,
      socket.assigns.interconnection,
      {type, component_id},
      socket.assigns.model_options,
      socket.assigns.simulation_hour
    )

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

  def handle_event("set_model_option", %{"option" => option, "enabled" => enabled}, socket) do
    with {:ok, option_key} <- parse_model_option(option),
         {:ok, enabled?} <- parse_boolean(enabled) do
      model_options = Map.put(socket.assigns.model_options, option_key, enabled?)
      teardown_sim_server(socket.assigns.sim_id)

      socket =
        socket
        |> assign(:model_options, model_options)
        |> assign(:cascade_steps, [])
        |> assign(:cascade_active, false)
        |> assign(:compensating_lines, [])
        |> assign(:last_dc_payload, nil)
        |> assign(:analysis_results, nil)
        |> assign(:solver_status, :idle)
        |> assign(:system_metrics, default_system_metrics())
        |> push_event("reset_grid", %{})
        |> push_event("deselect_highlight", %{})

      {:noreply, socket}
    else
      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("set_simulation_hour", %{"hour" => hour_value}, socket) do
    next_hour = parse_simulation_hour(hour_value)

    if next_hour == socket.assigns.simulation_hour do
      {:noreply, socket}
    else
      teardown_sim_server(socket.assigns.sim_id)

      socket =
        socket
        |> assign(:simulation_hour, next_hour)
        |> assign(:cascade_steps, [])
        |> assign(:cascade_active, false)
        |> assign(:compensating_lines, [])
        |> assign(:last_dc_payload, nil)
        |> assign(:analysis_results, nil)
        |> assign(:solver_status, :idle)
        |> assign(:system_metrics, default_system_metrics())
        |> push_event("reset_grid", %{})
        |> push_event("deselect_highlight", %{})

      {:noreply, socket}
    end
  end

  def handle_event("select_validation_case", %{"case_id" => case_id}, socket) do
    allowed_ids = socket.assigns.validation_cases |> Enum.map(& &1.id)

    if case_id in allowed_ids do
      {:noreply, assign(socket, :selected_validation_case_id, case_id)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("run_validation_case", _params, socket) do
    if socket.assigns.validation_running do
      {:noreply, socket}
    else
      case_id = socket.assigns.selected_validation_case_id

      if is_binary(case_id) do
        self_pid = self()

        Task.Supervisor.start_child(PowerModel.TaskSupervisor, fn ->
          result = Harness.run_fixture(case_id)
          send(self_pid, {:validation_case_finished, case_id, result})
        end)

        {:noreply, assign(socket, :validation_running, true)}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_event("run_validation_suite", _params, socket) do
    if socket.assigns.validation_running do
      {:noreply, socket}
    else
      self_pid = self()

      Task.Supervisor.start_child(PowerModel.TaskSupervisor, fn ->
        run = Harness.run_all()
        send(self_pid, {:validation_suite_finished, run})
      end)

      {:noreply, assign(socket, :validation_running, true)}
    end
  end

  def handle_event("clear_validation_report", _params, socket) do
    {:noreply, assign(socket, :validation_report, nil)}
  end

  # --- Harmonic controls ---

  def handle_event("harmonic_source_type", %{"value" => type, "gen-id" => gen_id}, socket) do
    component = socket.assigns.selected_component

    if component && to_string(component.id) == gen_id do
      component =
        Map.merge(component, %{
          harmonic_type: type,
          thd_result: nil,
          ieee_519_compliant: nil
        })

      {:noreply, assign(socket, :selected_component, component)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "harmonic_adjust",
        %{"value" => value, "gen-id" => gen_id, "harmonic" => h},
        socket
      ) do
    component = socket.assigns.selected_component
    harmonic_key = harmonic_slider_key(h)

    if component && to_string(component.id) == gen_id && harmonic_key do
      case Float.parse(value) do
        {val, _} ->
          component = Map.put(component, harmonic_key, val)
          {:noreply, assign(socket, :selected_component, component)}

        :error ->
          {:noreply, socket}
      end
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

    socket =
      socket
      |> assign(:cascade_steps, [])
      |> assign(:cascade_active, false)
      |> assign(:compensating_lines, [])
      |> assign(:last_dc_payload, nil)
      |> assign(:analysis_results, nil)
      |> assign(:selected_component, nil)
      |> assign(:solver_status, :idle)
      |> push_event("reset_grid", %{})
      |> push_event("deselect_highlight", %{})

    {:noreply, socket}
  end

  def handle_event("change_view_mode", %{"mode" => mode}, socket) do
    socket =
      socket
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
              {:noreply,
               push_event(socket, "lookup_error", %{
                 msg: "#{humanize_lookup_type(type)} ##{id} not found"
               })}

            component ->
              socket =
                socket
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
    socket =
      socket
      |> assign(:selected_component, nil)
      |> push_event("deselect_highlight", %{})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:simulation_dc_update, payload}, socket) do
    socket =
      socket
      |> assign(:solver_status, :dc_solved)
      |> assign(:compensating_lines, payload[:compensating_lines] || [])
      |> assign(:last_dc_payload, payload)
      |> update_metrics(payload)
      |> push_event("dc_results", payload)

    {:noreply, socket}
  end

  def handle_info({:simulation_ac_update, payload}, socket) do
    socket =
      socket
      |> assign(:solver_status, :ac_solved)
      |> update_metrics(payload)
      |> push_event("ac_results", payload)

    {:noreply, socket}
  end

  def handle_info({:simulation_cascade_step, payload}, socket) do
    steps = socket.assigns.cascade_steps ++ [payload]
    cumulative_trips = Enum.sum_by(steps, fn step -> Map.get(step, :trip_count, 0) end)

    socket =
      socket
      |> assign(:cascade_steps, steps)
      |> update(:system_metrics, fn metrics ->
        %{
          metrics
          | frequency_hz: Map.get(payload, :frequency_hz, metrics.frequency_hz),
            islands: Map.get(payload, :islands, metrics.islands),
            tripped_count: cumulative_trips
        }
      end)
      |> push_event("cascade_step", payload)

    {:noreply, socket}
  end

  def handle_info({:simulation_cascade_done, payload}, socket) do
    cascade_steps = socket.assigns.cascade_steps
    dc = socket.assigns.last_dc_payload || %{}
    final_step = build_final_step(cascade_steps, dc)
    steps = cascade_steps ++ [final_step]

    socket =
      socket
      |> assign(:cascade_steps, steps)
      |> assign(:cascade_active, false)
      |> assign(:solver_status, :stable)
      |> assign(:analysis_results, extract_analysis_results(payload))
      |> update(:system_metrics, fn m ->
        %{m | tripped_count: payload.total_events}
      end)
      |> push_event("cascade_step", final_step)

    {:noreply, socket}
  end

  def handle_info({:simulation_reset, _payload}, socket) do
    socket =
      socket
      |> assign(:cascade_steps, [])
      |> assign(:cascade_active, false)
      |> assign(:last_dc_payload, nil)
      |> assign(:analysis_results, nil)
      |> assign(:solver_status, :idle)
      |> assign(:system_metrics, default_system_metrics())

    {:noreply, socket}
  end

  def handle_info({:run_n1_screening, screening_opts}, socket) when is_list(screening_opts) do
    run_screening(socket, normalize_screening_opts(screening_opts))
  end

  def handle_info(:run_n1_screening, socket) do
    run_screening(socket, default_screening_opts())
  end

  def handle_info({:n1_screening_done, %{} = summary}, socket) do
    send_update(PowerModelWeb.GridLive.FailureControls,
      id: "failure-controls",
      screening: false,
      violations: Map.get(summary, :violations, 0),
      screening_summary: summary,
      screening_results: Map.get(summary, :top_results, [])
    )

    {:noreply, socket}
  end

  def handle_info({:n1_screening_done, violations}, socket) when is_integer(violations) do
    summary = %{default_screening_summary() | violations: max(violations, 0)}

    send_update(PowerModelWeb.GridLive.FailureControls,
      id: "failure-controls",
      screening: false,
      violations: summary.violations,
      screening_summary: summary,
      screening_results: summary.top_results
    )

    {:noreply, socket}
  end

  def handle_info({:validation_case_finished, _case_id, {:ok, result}}, socket) do
    report = %{
      mode: :single,
      generated_at: utc_timestamp(),
      case: summarize_validation_case(result)
    }

    {:noreply,
     socket
     |> assign(:validation_running, false)
     |> assign(:validation_report, report)}
  end

  def handle_info({:validation_case_finished, case_id, :error}, socket) do
    report = %{
      mode: :single_error,
      generated_at: utc_timestamp(),
      case_id: case_id
    }

    {:noreply,
     socket
     |> assign(:validation_running, false)
     |> assign(:validation_report, report)}
  end

  def handle_info({:validation_suite_finished, run}, socket) do
    report = %{
      mode: :suite,
      generated_at: utc_timestamp(),
      summary: run.summary,
      cases: Enum.map(run.results, &summarize_validation_case/1)
    }

    {:noreply,
     socket
     |> assign(:validation_running, false)
     |> assign(:validation_report, report)}
  end

  def handle_info({:harmonic_result, result}, socket) do
    component = socket.assigns.selected_component

    if component do
      component =
        Map.merge(component, %{
          thd_result: result.thd,
          ieee_519_compliant: result.compliant
        })

      {:noreply, assign(socket, :selected_component, component)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp run_screening(socket, screening_opts) do
    sim_id = socket.assigns.sim_id
    interconnection = socket.assigns.interconnection
    lv_pid = self()

    Task.Supervisor.start_child(PowerModel.TaskSupervisor, fn ->
      case ensure_sim_server(
             sim_id,
             interconnection,
             nil,
             socket.assigns.model_options,
             socket.assigns.simulation_hour
           ) do
        :ok ->
          case SimulationServer.screen_nk(sim_id, screening_opts) do
            {:ok, results} ->
              send(lv_pid, {:n1_screening_done, summarize_screening_results(results)})

            _ ->
              send(lv_pid, {:n1_screening_done, default_screening_summary()})
          end

        _ ->
          send(lv_pid, {:n1_screening_done, default_screening_summary()})
      end
    end)

    {:noreply, socket}
  end

  defp lookup_from_db("generator", id) do
    case PowerModel.Repo.get(PowerModel.Grid.Generator, id) do
      nil ->
        nil

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
      nil ->
        nil

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
      nil ->
        nil

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
      nil ->
        nil

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
      nil ->
        nil

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
      nil ->
        nil

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

      "transformer" ->
        "Estimated (multi-voltage substations)"

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

      _ ->
        nil
    end
  end

  defp resolve_data_source(_, _), do: nil

  defp run_harmonic_analysis(component) do
    bus_id = component[:bus_id]
    p_mw = component[:capacity] || 100.0
    harmonic_type = Map.get(component, :harmonic_type, "none")
    spectrum_pct = build_harmonic_spectrum(component, p_mw, harmonic_type)

    if is_integer(bus_id) and map_size(spectrum_pct) > 0 do
      with {:ok, snapshot} <- harmonic_snapshot_for_bus(bus_id),
           {:ok, result} <- run_harmonic_scenario(snapshot, bus_id, p_mw, spectrum_pct) do
        thd = Map.get(result.thd, bus_id, 0.0)

        compliant =
          case Enum.find(result.ieee_519, &(&1.bus_id == bus_id)) do
            nil -> thd < 5.0
            compliance -> compliance.compliant
          end

        %{thd: thd, compliant: compliant}
      else
        _ -> fallback_harmonic_analysis(spectrum_pct, p_mw)
      end
    else
      fallback_harmonic_analysis(spectrum_pct, p_mw)
    end
  end

  defp harmonic_snapshot_for_bus(bus_id) do
    import Ecto.Query

    interconnection_id =
      PowerModel.Repo.one(
        from b in PowerModel.Grid.Bus,
          where: b.id == ^bus_id,
          select: b.interconnection_id
      )

    snapshot =
      if is_integer(interconnection_id) do
        Grid.get_grid_snapshot(interconnection_id)
      else
        Grid.get_full_grid_snapshot()
      end

    {:ok, snapshot}
  rescue
    _ -> {:error, :snapshot_unavailable}
  end

  defp run_harmonic_scenario(snapshot, bus_id, p_mw, spectrum_pct) do
    device = %HarmonicDevice{
      id: {:ui_generator, bus_id},
      bus_id: bus_id,
      device_type: :custom,
      p_mw: p_mw,
      v_pu: 1.0,
      params: %{spectrum: spectrum_pct},
      active: true
    }

    scenario = %HarmonicScenario{
      devices: [device],
      filters: %{},
      max_harmonic: 15,
      base_mva: 100.0
    }

    HarmonicsScenario.run(scenario, snapshot, impedance_scan_buses: [bus_id])
  end

  defp fallback_harmonic_analysis(spectrum_pct, p_mw) do
    i_fund = p_mw / 100.0

    thd =
      if map_size(spectrum_pct) > 0 do
        sum_sq =
          Enum.reduce(spectrum_pct, 0.0, fn {_h, pct}, acc ->
            mag = i_fund * pct / 100.0
            acc + mag * mag
          end)

        :math.sqrt(sum_sq) / max(i_fund, 0.001) * 100.0
      else
        0.0
      end

    %{thd: thd, compliant: thd < 5.0}
  end

  defp build_harmonic_spectrum(component, p_mw, harmonic_type) do
    {base, i_ref} =
      case harmonic_type do
        "six_pulse" ->
          i_fund = p_mw / 100.0
          {Sources.six_pulse_spectrum(i_fund, max_harmonic: 15), max(i_fund, 1.0e-6)}

        "twelve_pulse" ->
          i_fund = p_mw / 100.0
          {Sources.twelve_pulse_spectrum(i_fund, max_harmonic: 15), max(i_fund, 1.0e-6)}

        "pwm_inverter" ->
          i_fund = p_mw / 100.0

          {Sources.pwm_inverter_spectrum(p_mw, 1.0, base_mva: 100.0, max_harmonic: 15),
           max(i_fund, 1.0e-6)}

        "arc_furnace" ->
          {Sources.arc_furnace_spectrum(p_mw, max_harmonic: 15), max(abs(p_mw), 1.0e-6)}

        _ ->
          {[], 1.0}
      end

    base_pct =
      base
      |> Enum.reduce(%{}, fn {h, mag, _angle}, acc ->
        Map.put(acc, h, mag / i_ref * 100.0)
      end)

    custom = %{
      5 => Map.get(component, :h5_pct, 0.0),
      7 => Map.get(component, :h7_pct, 0.0),
      11 => Map.get(component, :h11_pct, 0.0)
    }

    Enum.reduce(custom, base_pct, fn {h, pct}, acc ->
      if pct > 0.0 do
        Map.put(acc, h, pct)
      else
        Map.delete(acc, h)
      end
    end)
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
    source_label =
      case cf.category do
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

  defp ensure_sim_server(sim_id, interconnection, component, model_options, simulation_hour) do
    case Registry.lookup(PowerModel.SimulationRegistry, sim_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        interconnection_id =
          case interconnection do
            "all" -> resolve_interconnection(component)
            id -> String.to_integer(id)
          end

        hour_opts =
          if is_integer(simulation_hour) do
            [hour: simulation_hour]
          else
            []
          end

        opts =
          [sim_id: sim_id, interconnection_id: interconnection_id] ++
            model_option_keywords(model_options) ++ hour_opts

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

  defp teardown_sim_server(sim_id) do
    case Registry.lookup(PowerModel.SimulationRegistry, sim_id) do
      [{pid, _}] ->
        case DynamicSupervisor.terminate_child(PowerModel.SimulationSupervisor, pid) do
          :ok -> :ok
          {:error, :not_found} -> :ok
          {:error, :noproc} -> :ok
          _ -> :ok
        end

      [] ->
        :ok
    end
  end

  defp resolve_interconnection({"transmission_line", line_id}) do
    import Ecto.Query

    PowerModel.Repo.one(
      from tl in PowerModel.Grid.TransmissionLine,
        join: b in PowerModel.Grid.Bus,
        on: tl.from_bus_id == b.id,
        where: tl.id == ^line_id,
        select: b.interconnection_id
    )
  end

  defp resolve_interconnection({"generator", gen_id}) do
    import Ecto.Query

    PowerModel.Repo.one(
      from g in PowerModel.Grid.Generator,
        join: b in PowerModel.Grid.Bus,
        on: g.bus_id == b.id,
        where: g.id == ^gen_id,
        select: b.interconnection_id
    )
  end

  defp resolve_interconnection(_), do: nil

  defp update_metrics(socket, payload) do
    update(socket, :system_metrics, fn m ->
      %{
        m
        | total_gen_mw: payload[:total_gen_mw] || m.total_gen_mw,
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

  defp harmonic_slider_key("5"), do: :h5_pct
  defp harmonic_slider_key("7"), do: :h7_pct
  defp harmonic_slider_key("11"), do: :h11_pct
  defp harmonic_slider_key(_), do: nil

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
    all_tripped_lines =
      cascade_steps
      |> Enum.flat_map(&(&1[:tripped_line_ids] || []))
      |> Enum.uniq()

    all_tripped_gens =
      cascade_steps
      |> Enum.flat_map(&(&1[:tripped_generator_ids] || []))
      |> Enum.uniq()

    all_shed =
      cascade_steps
      |> Enum.flat_map(&(&1[:shed_ids] || []))
      |> Enum.uniq()

    all_water =
      cascade_steps
      |> Enum.flat_map(&(&1[:water_facility_ids] || []))
      |> Enum.uniq()

    all_critical =
      cascade_steps
      |> Enum.flat_map(&(&1[:critical_facility_ids] || []))
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

  defp validation_cases do
    Case.fixtures()
    |> Enum.map(fn validation_case ->
      %{
        id: validation_case.id,
        description: validation_case.description,
        tags: validation_case.tags
      }
    end)
  end

  defp default_validation_case_id([]), do: nil
  defp default_validation_case_id([first | _]), do: first.id

  defp default_model_options do
    %{
      use_ac: false,
      use_transient: false,
      use_opf: false,
      run_cpf: false,
      run_small_signal: false,
      run_harmonics: false
    }
  end

  defp default_system_metrics do
    %{
      total_gen_mw: 0.0,
      total_load_mw: 0.0,
      frequency_hz: 60.0,
      islands: 1,
      tripped_count: 0
    }
  end

  defp parse_model_option(option) do
    case option do
      "use_ac" -> {:ok, :use_ac}
      "use_transient" -> {:ok, :use_transient}
      "use_opf" -> {:ok, :use_opf}
      "run_cpf" -> {:ok, :run_cpf}
      "run_small_signal" -> {:ok, :run_small_signal}
      "run_harmonics" -> {:ok, :run_harmonics}
      _ -> :error
    end
  end

  defp parse_boolean("true"), do: {:ok, true}
  defp parse_boolean("false"), do: {:ok, false}
  defp parse_boolean(true), do: {:ok, true}
  defp parse_boolean(false), do: {:ok, false}
  defp parse_boolean(_), do: :error

  defp parse_simulation_hour("base"), do: nil

  defp parse_simulation_hour(value) when is_binary(value) do
    case Integer.parse(value) do
      {hour, _} when hour >= 0 and hour <= 23 -> hour
      _ -> nil
    end
  end

  defp parse_simulation_hour(value) when is_integer(value) and value >= 0 and value <= 23,
    do: value

  defp parse_simulation_hour(_), do: nil

  defp model_option_keywords(model_options) when is_map(model_options) do
    [
      use_ac: Map.get(model_options, :use_ac, false),
      use_transient: Map.get(model_options, :use_transient, false),
      use_opf: Map.get(model_options, :use_opf, false),
      run_cpf: Map.get(model_options, :run_cpf, false),
      run_small_signal: Map.get(model_options, :run_small_signal, false),
      run_harmonics: Map.get(model_options, :run_harmonics, false)
    ]
  end

  defp extract_analysis_results(payload) do
    %{
      stable: Map.get(payload, :stable, false),
      steps: Map.get(payload, :steps, 0),
      total_events: Map.get(payload, :total_events, 0),
      opf_total_cost: Map.get(payload, :opf_total_cost),
      voltage_margin_mw: Map.get(payload, :voltage_margin_mw),
      critical_bus_id: Map.get(payload, :critical_bus_id),
      small_signal_stable: Map.get(payload, :small_signal_stable),
      stability_modes: Map.get(payload, :stability_modes, []),
      stability_modes_count: length(Map.get(payload, :stability_modes, [])),
      transient_checks_run: Map.get(payload, :transient_checks_run),
      transient_unstable_checks: Map.get(payload, :transient_unstable_checks),
      transient_failed_checks: Map.get(payload, :transient_failed_checks),
      transient_last_stable: Map.get(payload, :transient_last_stable),
      transient_last_oos_count: Map.get(payload, :transient_last_oos_count),
      transient_last_min_frequency_hz: Map.get(payload, :transient_last_min_frequency_hz),
      transient_last_max_delta_deg: Map.get(payload, :transient_last_max_delta_deg),
      transient_last_duration_s: Map.get(payload, :transient_last_duration_s),
      harmonics_worst_thd: Map.get(payload, :harmonics_worst_thd),
      harmonics_violations: Map.get(payload, :harmonics_violations)
    }
  end

  defp summarize_validation_case(result) do
    metrics = result.replay.metrics

    failed_metrics =
      result.score.metrics
      |> Enum.filter(fn {_metric, score} -> not score.passed end)
      |> Enum.map(fn {metric, _} -> to_string(metric) end)

    %{
      id: result.case_id,
      description: result.description,
      score: result.score.score,
      passed: result.score.passed,
      stable: Map.get(metrics, :stable, false),
      min_frequency_hz: Map.get(metrics, :min_frequency_hz),
      ufls_shed_mw: Map.get(metrics, :ufls_shed_mw),
      blackout_load_mw: Map.get(metrics, :blackout_load_mw),
      transient_checks_run: Map.get(metrics, :transient_checks_run),
      transient_unstable_checks: Map.get(metrics, :transient_unstable_checks),
      out_of_step_event_count: Map.get(metrics, :out_of_step_event_count),
      cpf_result_present: Map.get(metrics, :cpf_result_present),
      voltage_margin_mw: Map.get(metrics, :voltage_margin_mw),
      critical_bus_id: Map.get(metrics, :critical_bus_id),
      small_signal_result_present: Map.get(metrics, :small_signal_result_present),
      small_signal_stable: Map.get(metrics, :small_signal_stable),
      stability_modes_count: Map.get(metrics, :stability_modes_count),
      harmonics_worst_thd_pct: Map.get(metrics, :harmonics_worst_thd_pct),
      harmonics_violations: Map.get(metrics, :harmonics_violations),
      failed_metrics: failed_metrics
    }
  end

  defp utc_timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp default_screening_summary do
    %{
      violations: 0,
      sampled_count: 0,
      worst_loading_pct: nil,
      worst_score: nil,
      top_results: []
    }
  end

  defp default_screening_opts do
    [k_range: 1..1, sample_size: 2_500, top_k: 30]
  end

  defp normalize_screening_opts(opts) do
    k_range =
      case Keyword.get(opts, :k_range, 1..1) do
        first..last//_ when is_integer(first) and is_integer(last) ->
          first = max(first, 1)
          last = max(last, first)
          first..last

        k when is_integer(k) ->
          1..max(k, 1)

        _ ->
          1..1
      end

    sample_size =
      opts
      |> Keyword.get(:sample_size, 2_500)
      |> normalize_bounded_int(2_500, 100, 50_000)

    top_k =
      opts
      |> Keyword.get(:top_k, 30)
      |> normalize_bounded_int(30, 1, 100)

    [k_range: k_range, sample_size: sample_size, top_k: top_k]
  end

  defp normalize_bounded_int(value, _fallback, min, max) when is_integer(value) do
    value
    |> Kernel.max(min)
    |> Kernel.min(max)
  end

  defp normalize_bounded_int(value, fallback, min, max) do
    case Integer.parse(to_string(value)) do
      {n, _} ->
        n
        |> Kernel.max(min)
        |> Kernel.min(max)

      :error ->
        fallback
    end
  end

  defp summarize_screening_results(results) when is_list(results) do
    severe_results =
      Enum.filter(results, fn result ->
        Map.get(result, :overloaded_count, 0) > 0 or Map.get(result, :island_split, false)
      end)

    sorted_results = Enum.sort_by(results, &Map.get(&1, :score, 0.0), :desc)
    top_source = if severe_results == [], do: sorted_results, else: severe_results
    worst = List.first(sorted_results)

    %{
      violations: length(severe_results),
      sampled_count: length(results),
      worst_loading_pct: if(worst, do: Map.get(worst, :max_loading_pct), else: nil),
      worst_score: if(worst, do: Map.get(worst, :score), else: nil),
      top_results:
        top_source
        |> Enum.take(8)
        |> Enum.map(&format_screening_result/1)
    }
  end

  defp format_screening_result(result) do
    label =
      result
      |> Map.get(:tripped, [])
      |> Enum.map(&screening_trip_label/1)
      |> Enum.join(", ")

    %{
      label: if(label == "", do: "(none)", else: label),
      max_loading_pct: Map.get(result, :max_loading_pct, 0.0),
      overloaded_count: Map.get(result, :overloaded_count, 0),
      mw_at_risk: Map.get(result, :mw_at_risk, 0.0),
      island_split: Map.get(result, :island_split, false),
      score: Map.get(result, :score, 0.0),
      severe:
        Map.get(result, :overloaded_count, 0) > 0 or
          Map.get(result, :island_split, false)
    }
  end

  defp screening_trip_label({:line, id}), do: "Line #{id}"
  defp screening_trip_label({:transformer, id}), do: "Xfmr #{id}"
  defp screening_trip_label({type, id}) when is_atom(type), do: "#{type} #{id}"
  defp screening_trip_label(other), do: inspect(other)

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
