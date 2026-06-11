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
    |> assign(:system_metrics, initial_metrics())
    |> assign(:solver_status, :idle)
    |> assign(:view_mode, "voltage_level")
    |> assign(:interconnection, "all")
    |> assign(:demand_range, PowerModel.Demand.available_range())
    |> assign(:selected_hour, nil)
    |> assign(:show_water, false)
    |> assign(:show_datacenters, false)
    |> assign(:hidden_legend, %{})
    |> assign(:show_utilization, false)
    |> assign(:utilization, nil)

    {:ok, socket, layout: {PowerModelWeb.Layouts, :grid}}
  end

  @impl true
  def handle_params(params, _url, socket) do
    interconnection = params["interconnection"] || "all"
    {:noreply, assign(socket, :interconnection, interconnection)}
  end

  @impl true
  def handle_event("select_component", %{"type" => type, "id" => id} = params, socket) do
    component = %{
      type: type,
      id: parse_int(id),
      capacity: parse_number(params["capacity"]),
      capacity_mgd: parse_number(params["capacityMgd"]),
      voltage: parse_number(params["voltage"]),
      voltage_kv: parse_number(params["voltageKv"]),
      rating_mva: parse_number(params["ratingMva"]),
      fuel_type: fuel_type_name(parse_int(params["fuelType"])),
      facility_type: facility_type_name(type, parse_int(params["facilityType"])),
      operator: params["operator"],
      power_mw: parse_number(params["powerMw"]),
      bus_id: parse_int(params["busId"]),
      state: parse_int(params["state"])
    }

    {:noreply, assign(socket, :selected_component, component)}
  end

  def handle_event("inject_failure", %{"type" => type, "id" => id}, socket) do
    sim_id = socket.assigns.sim_id
    component_id = String.to_integer(id)

    socket = assign(socket, :cascade_active, true)
    socket = assign(socket, :solver_status, :solving)

    # Ensure simulation server is running with the right interconnection
    ensure_sim_server(sim_id, socket.assigns.interconnection,
      socket.assigns.selected_hour, {type, component_id})

    lv = self()

    trip = fn ->
      result =
        case type do
          "transmission_line" -> SimulationServer.trip_branch(sim_id, component_id)
          "generator" -> SimulationServer.trip_generator(sim_id, component_id)
          _ -> :ok
        end

      case result do
        {:error, reason} when reason in [:not_in_network, :already_tripped] ->
          send(lv, {:trip_rejected, reason, type, component_id})

        _ ->
          :ok
      end
    end

    if type in ["transmission_line", "generator"], do: Task.start(trip)

    {:noreply, socket}
  end

  def handle_event("reset_simulation", _params, socket) do
    sim_id = socket.assigns.sim_id
    SimulationServer.reset(sim_id)

    socket = socket
    |> assign(:cascade_steps, [])
    |> assign(:cascade_active, false)
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

  def handle_event("select_hour", %{"date" => date_str, "hour" => hour_str}, socket) do
    selected =
      with {:ok, date} <- Date.from_iso8601(date_str),
           {hour, ""} when hour in 0..23 <- Integer.parse(hour_str),
           {:ok, naive} <- NaiveDateTime.new(date, Time.new!(hour, 0, 0)) do
        DateTime.from_naive!(naive, "Etc/UTC")
      else
        _ -> nil
      end

    {:noreply, apply_selected_hour(socket, selected)}
  end

  def handle_event("clear_hour", _params, socket) do
    {:noreply, apply_selected_hour(socket, nil)}
  end

  def handle_event("toggle_utilization", _params, socket) do
    if socket.assigns.show_utilization do
      {:noreply, assign(socket, :show_utilization, false)}
    else
      date =
        case socket.assigns.utilization do
          %{date: d} -> d
          _ -> default_utilization_date(socket.assigns)
        end

      socket = socket
      |> assign(:show_utilization, true)
      |> assign(:utilization, date && build_utilization(date))

      {:noreply, socket}
    end
  end

  def handle_event("set_util_date", %{"date" => date_str}, socket) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> {:noreply, assign(socket, :utilization, build_utilization(date))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("util_peak_day", _params, socket) do
    case PowerModel.Demand.peak_demand_date() do
      nil -> {:noreply, socket}
      date -> {:noreply, assign(socket, :utilization, build_utilization(date))}
    end
  end

  def handle_event("toggle_legend_item", %{"category" => category, "key" => key}, socket) do
    hidden = socket.assigns.hidden_legend
    set = Map.get(hidden, category, MapSet.new())

    set =
      if MapSet.member?(set, key),
        do: MapSet.delete(set, key),
        else: MapSet.put(set, key)

    hidden = Map.put(hidden, category, set)

    socket = socket
    |> assign(:hidden_legend, hidden)
    |> push_event("set_category_filters", %{
      voltage: hidden |> Map.get("voltage", MapSet.new()) |> MapSet.to_list(),
      fuel: hidden |> Map.get("fuel", MapSet.new()) |> MapSet.to_list(),
      water: hidden |> Map.get("water", MapSet.new()) |> MapSet.to_list(),
      datacenter: hidden |> Map.get("datacenter", MapSet.new()) |> MapSet.to_list()
    })

    {:noreply, socket}
  end

  def handle_event("set_layer_visibility", params, socket) do
    # The form reports explicit true/false for each layer (hidden-input
    # pattern), so server, checkbox, and map can never drift out of sync.
    show_water = params["water"] == "true"
    show_datacenters = params["datacenters"] == "true"

    socket = socket
    |> assign(:show_water, show_water)
    |> assign(:show_datacenters, show_datacenters)
    |> push_event("set_water_visibility", %{visible: show_water})
    |> push_event("set_datacenter_visibility", %{visible: show_datacenters})

    {:noreply, socket}
  end

  # PubSub handlers

  @impl true
  def handle_info({:simulation_dc_update, payload}, socket) do
    socket = socket
    |> assign(:solver_status, :dc_solved)
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
    |> update(:system_metrics, fn m ->
      m
      |> merge_balance(payload[:balance])
      |> Map.put(:islands, payload[:islands] || m.islands)
    end)
    |> push_event("cascade_step", payload)

    {:noreply, socket}
  end

  def handle_info({:simulation_cascade_done, payload}, socket) do
    socket = socket
    |> assign(:cascade_active, false)
    |> assign(:solver_status, :stable)
    |> update(:system_metrics, fn m ->
      m
      |> merge_balance(payload[:balance])
      |> Map.put(:tripped_count, payload.total_events)
    end)

    {:noreply, socket}
  end

  def handle_info({:simulation_reset, _payload}, socket) do
    socket = socket
    |> assign(:cascade_steps, [])
    |> assign(:cascade_active, false)
    |> assign(:solver_status, :idle)
    |> assign(:system_metrics, initial_metrics())

    {:noreply, socket}
  end

  def handle_info(:run_n1_screening, socket) do
    sim_id = socket.assigns.sim_id
    # self() inside the Task closure would be the Task's pid, not this LiveView
    lv = self()
    interconnection = socket.assigns.interconnection
    hour = socket.assigns.selected_hour

    Task.start(fn ->
      ensure_sim_server(sim_id, interconnection, hour)

      case SimulationServer.get_state(sim_id) do
        %{has_dc_solution: true} = state ->
          # N-1 screening would run here against the current DC solution
          # For now, broadcast the result count back
          violations = length(state.tripped_lines) + length(state.tripped_generators)
          send(lv, {:n1_screening_done, violations})
        _ ->
          send(lv, {:n1_screening_done, 0})
      end
    end)

    {:noreply, socket}
  end

  def handle_info({:trip_rejected, reason, _type, _id}, socket) do
    socket = socket
    |> assign(:cascade_active, false)
    |> assign(:solver_status, reason)

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

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Private

  defp ensure_sim_server(sim_id, interconnection, hour, component \\ nil) do
    case Registry.lookup(PowerModel.SimulationRegistry, sim_id) do
      [{_pid, _}] -> :ok
      [] ->
        interconnection_id = case interconnection do
          "all" -> resolve_interconnection(component)
          id -> String.to_integer(id)
        end

        opts = [sim_id: sim_id, interconnection_id: interconnection_id, hour: hour]

        DynamicSupervisor.start_child(
          PowerModel.SimulationSupervisor,
          {SimulationServer, opts}
        )
    end
  end

  # Changing the demand hour invalidates the running simulation's snapshot;
  # terminate it so the next failure injection rebuilds at the new hour.
  defp apply_selected_hour(socket, selected_hour) do
    stop_sim_server(socket.assigns.sim_id)

    socket
    |> assign(:selected_hour, selected_hour)
    |> assign(:cascade_steps, [])
    |> assign(:cascade_active, false)
    |> assign(:selected_component, nil)
    |> assign(:solver_status, :idle)
    |> assign(:system_metrics, initial_metrics())
    |> push_event("reset_grid", %{})
    |> push_event("deselect_highlight", %{})
  end

  defp stop_sim_server(sim_id) do
    case Registry.lookup(PowerModel.SimulationRegistry, sim_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(PowerModel.SimulationSupervisor, pid)
      [] -> :ok
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

  defp initial_metrics do
    %{
      total_gen_mw: 0.0,
      total_load_mw: 0.0,
      total_loss_mw: 0.0,
      mismatch_mw: 0.0,
      demand_mw: 0.0,
      served_mw: 0.0,
      shed_mw: 0.0,
      blackout_mw: 0.0,
      frequency_hz: 60.0,
      islands: 1,
      tripped_count: 0,
      overload: %{
        overloaded_count: 0,
        max_loading_pct: 0.0,
        overload_mw: 0.0,
        monitored_count: 0,
        unrated_count: 0
      }
    }
  end

  defp update_metrics(socket, payload) do
    update(socket, :system_metrics, fn m ->
      %{m |
        total_gen_mw: payload[:total_gen_mw] || m.total_gen_mw,
        total_load_mw: payload[:total_load_mw] || m.total_load_mw,
        total_loss_mw: payload[:total_loss_mw] || m.total_loss_mw,
        mismatch_mw: payload[:mismatch_mw] || m.mismatch_mw,
        overload: payload[:overload_summary] || m.overload
      }
    end)
  end

  defp merge_balance(metrics, nil), do: metrics

  defp merge_balance(metrics, balance) do
    %{metrics |
      demand_mw: balance[:original_load_mw] || metrics.demand_mw,
      served_mw: balance[:served_load_mw] || metrics.served_mw,
      shed_mw: balance[:shed_load_mw] || metrics.shed_mw,
      blackout_mw: balance[:blackout_load_mw] || metrics.blackout_mw
    }
  end

  defp solver_status_class(:idle), do: "status-idle"
  defp solver_status_class(:solving), do: "status-solving"
  defp solver_status_class(:dc_solved), do: "status-dc"
  defp solver_status_class(:ac_solved), do: "status-ac"
  defp solver_status_class(:stable), do: "status-stable"
  defp solver_status_class(:not_in_network), do: "status-rejected"
  defp solver_status_class(:already_tripped), do: "status-rejected"
  defp solver_status_class(_), do: "status-idle"

  defp solver_status_text(:idle), do: "Idle"
  defp solver_status_text(:solving), do: "Solving..."
  defp solver_status_text(:dc_solved), do: "DC Solved"
  defp solver_status_text(:ac_solved), do: "AC Converged"
  defp solver_status_text(:stable), do: "Stable"
  defp solver_status_text(:not_in_network), do: "Not in simulated network"
  defp solver_status_text(:already_tripped), do: "Already tripped"
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

  defp facility_type_name("datacenter", code), do: datacenter_type_name(code)
  defp facility_type_name(_type, code), do: water_facility_type_name(code)

  defp water_facility_type_name(nil), do: nil
  defp water_facility_type_name(0), do: "Unknown"
  defp water_facility_type_name(1), do: "Desalination"
  defp water_facility_type_name(2), do: "Wastewater Treatment"
  defp water_facility_type_name(3), do: "Water Treatment"
  defp water_facility_type_name(4), do: "Pump Station"
  defp water_facility_type_name(5), do: "Reservoir"
  defp water_facility_type_name(6), do: "Pipeline"
  defp water_facility_type_name(_), do: "Other"

  defp datacenter_type_name(nil), do: nil
  defp datacenter_type_name(1), do: "Hyperscale"
  defp datacenter_type_name(2), do: "Colocation"
  defp datacenter_type_name(3), do: "AI Training"
  defp datacenter_type_name(4), do: "Enterprise"
  defp datacenter_type_name(5), do: "Crypto"
  defp datacenter_type_name(_), do: "Datacenter"

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

  # ---------------------------------------------------------------------------
  # Interconnection utilization panel
  # ---------------------------------------------------------------------------

  @ic_colors %{1 => "#6ea8fe", 2 => "#ffb84d", 3 => "#2ecc71"}

  # Chart geometry (SVG user units)
  @chart_w 660
  @chart_h 240
  @pad_l 52
  @pad_r 12
  @pad_t 12
  @pad_b 26

  defp default_utilization_date(assigns) do
    case assigns.selected_hour do
      %DateTime{} = dt -> DateTime.to_date(dt)
      _ -> PowerModel.Demand.peak_demand_date()
    end
  end

  defp build_utilization(%Date{} = date) do
    capacity = PowerModel.Demand.interconnection_capacity()
    demand = PowerModel.Demand.interconnection_demand_for_date(date)

    names =
      PowerModel.Grid.list_interconnections()
      |> Map.new(&{&1.id, &1.name})

    series =
      demand
      |> Enum.sort_by(fn {ic, _} -> ic end)
      |> Enum.map(fn {ic, hours} ->
        cap = Map.get(capacity, ic, 0.0)
        {peak_hour, peak_mw} = Enum.max_by(hours, fn {_h, mw} -> mw end, fn -> {0, 0.0} end)
        {min_hour, min_mw} = Enum.min_by(hours, fn {_h, mw} -> mw end, fn -> {0, 0.0} end)

        %{
          id: ic,
          name: Map.get(names, ic, "Interconnection #{ic}"),
          color: Map.get(@ic_colors, ic, "#aaaaaa"),
          hours: Enum.sort(hours),
          capacity_mw: cap,
          peak_mw: peak_mw,
          peak_hour: peak_hour,
          min_mw: min_mw,
          min_hour: min_hour,
          peak_util_pct: if(cap > 0, do: peak_mw / cap * 100.0, else: 0.0)
        }
      end)

    y_max =
      series
      |> Enum.flat_map(fn s -> [s.capacity_mw, s.peak_mw] end)
      |> Enum.max(fn -> 1.0 end)
      |> Kernel.*(1.08)

    %{date: date, series: series, y_max: y_max}
  end

  defp chart_w, do: @chart_w
  defp chart_h, do: @chart_h
  defp pad_l, do: @pad_l
  defp pad_r, do: @pad_r

  defp chart_x(hour), do: @pad_l + hour / 23 * (@chart_w - @pad_l - @pad_r)

  defp chart_y(mw, y_max) do
    @chart_h - @pad_b - mw / y_max * (@chart_h - @pad_t - @pad_b)
  end

  defp demand_points(hours, y_max) do
    hours
    |> Enum.map(fn {h, mw} -> "#{Float.round(chart_x(h), 1)},#{Float.round(chart_y(mw, y_max), 1)}" end)
    |> Enum.join(" ")
  end

  defp format_gw(mw), do: "#{Float.round(mw / 1000.0, 1)} GW"

  attr :utilization, :map, required: true

  defp utilization_panel(assigns) do
    ~H"""
    <div class="util-panel">
      <div class="util-header">
        <h3>Grid Utilization — <%= Calendar.strftime(@utilization.date, "%a, %b %d %Y") %> (UTC)</h3>
        <button phx-click="toggle_utilization" class="close-btn">&times;</button>
      </div>

      <div class="util-controls">
        <form phx-change="set_util_date">
          <input type="date" name="date" value={Date.to_iso8601(@utilization.date)} class="hour-date" />
        </form>
        <button phx-click="util_peak_day" class="util-peak-btn">Peak day</button>
      </div>

      <svg viewBox={"0 0 #{chart_w()} #{chart_h()}"} class="util-chart" preserveAspectRatio="xMidYMid meet">
        <%!-- horizontal gridlines at quarter intervals --%>
        <%= for frac <- [0.25, 0.5, 0.75, 1.0] do %>
          <line
            x1={pad_l()} x2={chart_w() - pad_r()}
            y1={Float.round(chart_y(@utilization.y_max * frac, @utilization.y_max), 1)}
            y2={Float.round(chart_y(@utilization.y_max * frac, @utilization.y_max), 1)}
            stroke="rgba(120,120,140,0.18)" stroke-width="1"
          />
          <text
            x={pad_l() - 6}
            y={Float.round(chart_y(@utilization.y_max * frac, @utilization.y_max) + 3, 1)}
            class="util-axis-label" text-anchor="end"
          ><%= format_gw(@utilization.y_max * frac) %></text>
        <% end %>

        <%!-- x axis labels --%>
        <%= for h <- [0, 6, 12, 18, 23] do %>
          <text x={Float.round(chart_x(h), 1)} y={chart_h() - 8} class="util-axis-label" text-anchor="middle">
            <%= String.pad_leading("#{h}", 2, "0") %>:00
          </text>
        <% end %>

        <%!-- capacity reference lines (dashed) + demand curves --%>
        <%= for s <- @utilization.series do %>
          <%= if s.capacity_mw > 0 do %>
            <line
              x1={pad_l()} x2={chart_w() - pad_r()}
              y1={Float.round(chart_y(s.capacity_mw, @utilization.y_max), 1)}
              y2={Float.round(chart_y(s.capacity_mw, @utilization.y_max), 1)}
              stroke={s.color} stroke-width="1" stroke-dasharray="5,4" opacity="0.55"
            />
          <% end %>
          <polyline
            points={demand_points(s.hours, @utilization.y_max)}
            fill="none" stroke={s.color} stroke-width="2"
            stroke-linejoin="round" stroke-linecap="round"
          />
        <% end %>
      </svg>

      <div class="util-stats">
        <%= for s <- @utilization.series do %>
          <div class="util-stat" style={"border-left: 3px solid #{s.color};"}>
            <div class="util-stat-name"><%= s.name %></div>
            <div class="util-stat-row">
              <span>Capacity</span><span><%= format_gw(s.capacity_mw) %></span>
            </div>
            <div class="util-stat-row">
              <span>Peak</span>
              <span><%= format_gw(s.peak_mw) %> @ <%= String.pad_leading("#{s.peak_hour}", 2, "0") %>:00</span>
            </div>
            <div class="util-stat-row">
              <span>Trough</span>
              <span><%= format_gw(s.min_mw) %> @ <%= String.pad_leading("#{s.min_hour}", 2, "0") %>:00</span>
            </div>
            <div class="util-stat-row util-stat-em">
              <span>Peak utilization</span>
              <span><%= Float.round(s.peak_util_pct, 1) %>%</span>
            </div>
          </div>
        <% end %>
      </div>

      <div class="util-footnote">
        Demand: EIA-930 actuals summed per interconnection. Capacity: modeled nameplate
        of the simulated network — dashed lines. Times UTC.
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Legend visibility toggles
  # ---------------------------------------------------------------------------

  @voltage_legend [
    {"69", "69 kV", "rgb(100, 149, 237)"},
    {"138", "138 kV", "rgb(64, 224, 208)"},
    {"230", "230 kV", "rgb(50, 205, 50)"},
    {"345", "345 kV", "rgb(255, 165, 0)"},
    {"500", "500 kV", "rgb(255, 69, 0)"},
    {"765", "765 kV", "rgb(220, 20, 60)"}
  ]

  @fuel_legend [
    {"gas", "Natural Gas", "rgb(65, 131, 215)"},
    {"coal", "Coal", "rgb(100, 100, 100)"},
    {"nuclear", "Nuclear", "rgb(155, 89, 182)"},
    {"hydro", "Hydro", "rgb(52, 152, 219)"},
    {"wind", "Wind", "rgb(46, 204, 113)"},
    {"solar", "Solar", "rgb(241, 196, 15)"},
    {"geothermal", "Geothermal", "rgb(230, 126, 34)"},
    {"import", "Import (Intl)", "rgb(0, 255, 255)"},
    {"other", "Other", "rgb(150, 150, 150)"}
  ]

  @datacenter_legend [
    {"hyperscale", "Hyperscale", "rgb(80, 200, 255)"},
    {"colocation", "Colocation", "rgb(180, 140, 255)"},
    {"ai_training", "AI Training", "rgb(255, 120, 200)"},
    {"enterprise", "Enterprise", "rgb(160, 180, 200)"}
  ]

  defp voltage_legend, do: @voltage_legend
  defp fuel_legend, do: @fuel_legend
  defp datacenter_legend, do: @datacenter_legend

  defp legend_hidden?(hidden, category, key) do
    hidden |> Map.get(category, MapSet.new()) |> MapSet.member?(key)
  end

  attr :category, :string, required: true
  attr :key, :string, required: true
  attr :label, :string, required: true
  attr :hidden, :boolean, default: false
  slot :inner_block, required: true

  defp legend_item(assigns) do
    ~H"""
    <div
      class={"legend-item legend-item-toggle" <> if(@hidden, do: " legend-item-off", else: "")}
      phx-click="toggle_legend_item"
      phx-value-category={@category}
      phx-value-key={@key}
      title={if(@hidden, do: "Click to show", else: "Click to hide")}
    >
      <%= render_slot(@inner_block) %>
      <span><%= @label %></span>
    </div>
    """
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
