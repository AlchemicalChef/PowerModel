defmodule PowerModelWeb.GridLive.Index do
  use PowerModelWeb, :live_view

  require Logger

  alias PowerModel.Analysis.ContingencyScreening
  alias PowerModel.Engine.SimulationServer
  alias PowerModel.Solver.Partition

  # UI-M11: an N-1 screen that neither reports nor dies within this window is
  # declared failed so the button never sticks at "Scanning...".
  #
  # UIW-2: 60 s was BELOW the work. A full Eastern sweep measured 63.0-65.5 s
  # of wall time on its own, so the old deadline declared the real screen
  # failed seconds before it would have reported. The budget is now per scope:
  # a single interconnection gets ~2x its measured worst case, and "all"
  # additionally pays for partitioning and base-solving the national snapshot
  # before the sweep it feeds is the Eastern one anyway.
  @n1_budget_scoped_ms 120_000
  @n1_budget_national_ms 240_000

  # Ranked entries kept from a sweep. The summary is computed over every
  # contingency screened regardless of this (ContingencyScreening.screen/2),
  # so trimming the list costs no counts.
  @n1_ranked_limit 10

  @impl true
  def mount(_params, _session, socket) do
    # CAS-6: node-local unique_integer collides across cluster nodes on the
    # cluster-wide PubSub; the sim id must be globally unique.
    sim_id = "sim_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    # ENE-1: default to the latest hour with real EIA-930 demand; the raw
    # baseline is ~2x real demand and only acceptable as an explicit choice.
    default_hour = PowerModel.Demand.latest_demand_hour()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(PowerModel.PubSub, "simulation:#{sim_id}")

      if is_nil(default_hour) do
        Logger.warning(
          "no EIA-930 demand data loaded -- simulations will run on the " <>
            "synthetic BASELINE load (~2x real demand)"
        )
      end
    end

    socket =
      socket
      |> assign(:sim_id, sim_id)
      |> assign(:selected_component, nil)
      |> assign(:cascade_steps, [])
      |> assign(:cascade_active, false)
      |> assign_cascade_events(:reset)
      |> assign(:system_metrics, initial_metrics())
      |> put_status(:idle)
      |> assign(:view_mode, "voltage_level")
      |> assign(:interconnection, "all")
      |> assign(:demand_range, PowerModel.Demand.available_range())
      |> assign(:selected_hour, default_hour)
      |> assign(:show_water, false)
      |> assign(:show_datacenters, false)
      |> assign(:show_demand_density, false)
      |> assign(:hidden_legend, %{})
      |> assign(:show_utilization, false)
      |> assign(:utilization, nil)
      |> assign(:sim_server, nil)
      |> assign(:server_scope, nil)
      # UI-M20: the server's topology generation, learned from the payloads
      # that carry it (cascade_done, reset). `nil` means "no information" --
      # a fresh or restarted server, where an N-1 result has nothing to be
      # stale against and the staleness flag alone governs.
      |> assign(:sim_epoch, nil)
      |> assign(:trip_task, nil)
      |> assign(:reset_task, nil)
      |> assign_n1_task(:reset)
      |> assign_n1(:reset)

    {:ok, socket, layout: {PowerModelWeb.Layouts, :grid}}
  end

  @impl true
  def handle_params(params, _url, socket) do
    # UI-H1: the raw query param used to reach String.to_integer unvalidated
    interconnection = validate_interconnection(params["interconnection"])
    {:noreply, assign(socket, :interconnection, interconnection)}
  end

  # CAS-4: a closed browser session must not leave a permanent GenServer
  # holding a full grid snapshot (the server's idle timeout is the backstop
  # for brutal kills that skip terminate/2).
  @impl true
  def terminate(_reason, socket) do
    with sim_id when is_binary(sim_id) <- socket.assigns[:sim_id],
         [{pid, _}] <- Registry.lookup(PowerModel.SimulationRegistry, sim_id) do
      DynamicSupervisor.terminate_child(PowerModel.SimulationSupervisor, pid)
    end

    :ok
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

  def handle_event("inject_failure", %{"type" => type, "id" => id}, socket)
      when type in ["transmission_line", "generator", "transformer"] do
    # UI-M22: one injection at a time. A second click while the first cascade
    # is still running orphaned the first trip's monitor, and the second call's
    # {:error, :already_tripped} reply landed MID-CASCADE -- flipping
    # cascade_active back to false and captioning a running cascade "Already
    # tripped", with the inject button offered again on top of it.
    if socket.assigns.cascade_active do
      {:noreply, socket}
    else
      inject_failure(socket, type, id)
    end
  end

  # Non-trippable component types (water facilities, datacenters, ...) must
  # not flip the UI into a cascade state that never resolves.
  def handle_event("inject_failure", _params, socket), do: {:noreply, socket}

  def handle_event("reset_simulation", _params, socket) do
    # CAS-13 / UI-C2: the reset call used to run a full base-case solve
    # inline in the LiveView (up to ~2 min frozen UI) and a dead server
    # (:noproc) killed the view. Run it in a monitored task; exits caught.
    sim_id = socket.assigns.sim_id
    lv = self()

    {:ok, task_pid} =
      Task.start(fn ->
        result =
          try do
            SimulationServer.reset(sim_id)
          catch
            :exit, reason -> {:error, reason}
          end

        send(lv, {:reset_finished, result})
      end)

    socket =
      socket
      |> assign(:reset_task, Process.monitor(task_pid))
      |> assign(:cascade_steps, [])
      |> assign_cascade_events(:reset)
      |> assign(:cascade_active, false)
      |> assign(:selected_component, nil)
      |> put_status(:resetting)
      |> assign(:system_metrics, initial_metrics())
      # UI-M20: an in-flight sweep must not repopulate the panel after the
      # reset cleared it -- it is a linearisation about a network the user
      # has just asked to be rebuilt.
      |> assign_n1_task(:cancel)
      |> assign_n1(:reset)
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

  def handle_event("map_click", %{"lon" => _lon, "lat" => _lat}, socket) do
    {:noreply, socket}
  end

  # UIW-8: the client's own ViewportTracker already rebuilt the LOD before it
  # told us; echoing the viewport back made the map rebuild ~90k line paths a
  # second time per pan. The server has nothing to add to a viewport change.
  def handle_event("viewport_changed", %{"zoom" => _zoom, "bounds" => _bounds}, socket) do
    {:noreply, socket}
  end

  def handle_event("run_n1_screening", _params, socket) do
    # UI-M23: one sweep at a time. Two fast clicks used to launch two full
    # sweeps (240 s of national CPU each), orphan the first task's monitor,
    # and let whichever finished last overwrite the other -- which can be the
    # OLDER ranking. The button is disabled while `@screening`, so this only
    # fires on a click that raced the re-render.
    if socket.assigns.n1_screening or socket.assigns.n1_task do
      {:noreply, socket}
    else
      send(self(), :run_n1_screening)

      socket =
        socket
        |> assign(:n1_screening, true)
        |> assign(:n1_error, false)
        |> assign(:n1_hint, n1_hint(socket.assigns.interconnection))

      {:noreply, socket}
    end
  end

  def handle_event("scrub_timeline", %{"step" => step}, socket) do
    # Contract #4: `step` is the 0-based ARRAY POSITION in the frame list
    # (never the cascade's own step number). UI-H1: validated, not trusted.
    case parse_int(step) do
      nil -> {:noreply, socket}
      idx -> {:noreply, push_event(socket, "show_cascade_step", %{step: idx})}
    end
  end

  def handle_event("deselect", _params, socket) do
    socket =
      socket
      |> assign(:selected_component, nil)
      |> push_event("deselect_highlight", %{})

    {:noreply, socket}
  end

  def handle_event("select_hour", %{"date" => date_str, "hour" => hour_str}, socket) do
    with {:ok, date} <- Date.from_iso8601(date_str),
         {hour, ""} when hour in 0..23 <- Integer.parse(hour_str),
         {:ok, naive} <- NaiveDateTime.new(date, Time.new!(hour, 0, 0)) do
      {:noreply, apply_selected_hour(socket, DateTime.from_naive!(naive, "Etc/UTC"))}
    else
      # UI-M5: an incomplete selection (date typed but no hour picked yet,
      # or vice versa) must not destroy the running simulation -- keep the
      # current hour until both fields are valid.
      _ -> {:noreply, socket}
    end
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

      socket =
        socket
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

    socket =
      socket
      |> assign(:hidden_legend, hidden)
      |> push_event("set_category_filters", %{
        voltage: hidden |> Map.get("voltage", MapSet.new()) |> MapSet.to_list(),
        fuel: hidden |> Map.get("fuel", MapSet.new()) |> MapSet.to_list(),
        water: hidden |> Map.get("water", MapSet.new()) |> MapSet.to_list(),
        datacenter: hidden |> Map.get("datacenter", MapSet.new()) |> MapSet.to_list(),
        equipment: hidden |> Map.get("equipment", MapSet.new()) |> MapSet.to_list()
      })

    {:noreply, socket}
  end

  def handle_event("set_layer_visibility", params, socket) do
    # The form reports explicit true/false for each layer (hidden-input
    # pattern), so server, checkbox, and map can never drift out of sync.
    show_water = params["water"] == "true"
    show_datacenters = params["datacenters"] == "true"
    show_demand_density = params["demand_density"] == "true"

    socket =
      socket
      |> assign(:show_water, show_water)
      |> assign(:show_datacenters, show_datacenters)
      |> assign(:show_demand_density, show_demand_density)
      |> push_event("set_water_visibility", %{visible: show_water})
      |> push_event("set_datacenter_visibility", %{visible: show_datacenters})
      |> push_event("set_demand_density_visibility", %{visible: show_demand_density})

    {:noreply, socket}
  end

  # UI-M13: an unknown or malformed client event must never crash the view.
  def handle_event(event, params, socket) do
    Logger.warning("ignoring unhandled event #{inspect(event)} with params #{inspect(params)}")

    {:noreply, socket}
  end

  # PubSub handlers

  @impl true
  def handle_info({:simulation_dc_update, payload}, socket) do
    socket =
      socket
      |> put_solver_result_status(:dc_solved)
      |> update_metrics(payload)
      |> push_event("dc_results", payload)

    {:noreply, socket}
  end

  def handle_info({:simulation_ac_update, payload}, socket) do
    # UIW-4: the only AC that runs now is the cascade's own per-island QSS-AC,
    # and it covers the islands that converged and no others. Labelling that
    # "AC Converged" would claim a whole-grid voltage solution the server
    # explicitly did not produce.
    status = if payload[:partial_ac], do: :ac_partial, else: :ac_solved

    socket =
      socket
      |> put_solver_result_status(status)
      |> update_metrics(payload)
      |> push_event("ac_results", payload)

    {:noreply, socket}
  end

  def handle_info({:simulation_cascade_step, payload}, socket) do
    steps = socket.assigns.cascade_steps ++ [payload]

    socket =
      socket
      |> assign(:cascade_steps, steps)
      |> assign_cascade_events({:step, payload})
      |> assign(:n1_stale, socket.assigns.n1_stale or step_component_trips(payload) > 0)
      |> update(:system_metrics, fn m ->
        m
        |> merge_balance(payload[:balance])
        |> Map.put(:islands, payload[:islands] || m.islands)
        # UI-M3: the Tripped metric moves WITH the cascade, not only at the end
        |> Map.update!(:tripped_count, &(&1 + step_component_trips(payload)))
        |> track_frequency(payload)
        |> merge_present(:voltage_layer, payload[:voltage_layer])
        |> merge_present(:agc, payload[:agc])
      end)
      # UIW-5: the browser gets the map channels only. The panel channels
      # (:trips and friends) are 83% of a collapse-scale frame and no JS
      # consumer reads them -- the LiveView above is their only reader.
      |> push_event("cascade_step", SimulationServer.client_step_payload(payload))

    {:noreply, socket}
  end

  def handle_info({:simulation_cascade_done, payload}, socket) do
    # CAS-3: an unstable end state (blackout, exhausted step budget) must not
    # be presented as "Stable". UIW-3: and a run that stopped at the step
    # BUDGET is not the same claim as one that settled into collapse -- the
    # cascade's own :reason is the only thing that separates them, and reading
    # a truncated run as a collapse is the false-10x hazard.
    stable = payload[:stable] == true
    {status, note} = cascade_status(payload[:reason], payload[:outcome], stable)

    socket =
      socket
      |> assign(:cascade_active, false)
      |> track_sim_epoch(payload)
      |> put_status(status, note)
      |> update(:system_metrics, fn m ->
        m
        |> merge_balance(payload[:balance])
        # CAS-8: component trips only -- never total_events (one per shed load)
        |> Map.put(:tripped_count, payload[:tripped_count] || m.tripped_count)
        |> merge_present(:voltage_layer, payload[:voltage_layer])
        |> merge_present(:agc, payload[:agc])
        |> merge_present(:btm_trip_breakdown, payload[:btm_trip_breakdown])
      end)
      # UI-C1 / contract #2: tell the map the cascade ended so it can leave
      # cascade mode (ghosting, vignette, forced layers).
      |> push_event("cascade_done", %{stable: stable})

    {:noreply, socket}
  end

  def handle_info({:simulation_reset, payload}, socket) do
    socket =
      socket
      |> assign(:cascade_steps, [])
      |> assign_cascade_events(:reset)
      |> assign(:cascade_active, false)
      |> track_sim_epoch(payload)
      |> put_status(:idle)
      |> assign(:system_metrics, initial_metrics())
      |> assign_n1(:reset)
      # UI-M14: server-side frame list is cleared above; without this push the
      # client keeps its frames and every later scrub replays the wrong prefix.
      |> push_event("reset_grid", %{})

    {:noreply, socket}
  end

  def handle_info(:run_n1_screening, socket) do
    # UI-M23: the second of two queued launches -- the first is already
    # running, and spawning another would orphan its monitor.
    if socket.assigns.n1_task do
      {:noreply, socket}
    else
      launch_n1_screening(socket)
    end
  end

  def handle_info({:trip_rejected, reason, _type, _id}, socket) do
    # UI-M22: a rejection belongs to an injection this view is still waiting
    # on. With no trip task in flight it is a leftover from a run that has
    # already ended, and applying it would caption the current state with an
    # old one's verdict.
    if socket.assigns.trip_task do
      {:noreply, socket |> assign(:cascade_active, false) |> put_status(reason)}
    else
      {:noreply, socket}
    end
  end

  # CAS-5 / UI-C3: the trip task hit a server crash or unexpected error --
  # leave the cascade state instead of spinning forever.
  def handle_info({:trip_failed, reason, type, id}, socket) do
    Logger.error("trip of #{type} #{id} failed: #{inspect(reason)}")
    {:noreply, fail_simulation(socket)}
  end

  def handle_info({:reset_finished, result}, socket) do
    socket = assign(socket, :reset_task, nil)

    case result do
      :ok ->
        # The server's "reset" broadcast flips :resetting -> :idle
        {:noreply, socket}

      {:error, {reason, _call}} when reason in [:noproc, :normal, :shutdown] ->
        # No server running -- nothing to reset; the cleared UI is correct
        {:noreply, put_status(socket, :idle)}

      {:error, reason} ->
        Logger.error("simulation reset failed: #{inspect(reason)}")
        {:noreply, put_status(socket, :error)}
    end
  end

  def handle_info({:n1_screening_done, result}, socket) do
    socket = assign_n1_task(socket, :reset)

    case result do
      {:ok, screen} ->
        {:noreply, assign_n1(socket, {:result, screen})}

      {:error, reason} ->
        Logger.error("N-1 screening failed: #{inspect(reason)}")
        {:noreply, assign_n1(socket, :error)}
    end
  end

  def handle_info({:n1_screening_timeout, ref}, socket) do
    if socket.assigns.n1_task == ref do
      Logger.error(
        "N-1 screening timed out after #{n1_budget_ms(socket.assigns.interconnection)}ms"
      )

      {:noreply, socket |> assign_n1_task(:cancel) |> assign_n1(:error)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    cond do
      match?({_pid, ^ref}, socket.assigns.sim_server) ->
        handle_sim_server_down(socket, reason)

      socket.assigns.trip_task == ref ->
        socket = assign(socket, :trip_task, nil)

        if reason == :normal do
          {:noreply, socket}
        else
          Logger.error("trip task died: #{inspect(reason)}")
          {:noreply, fail_simulation(socket)}
        end

      socket.assigns.reset_task == ref ->
        socket = assign(socket, :reset_task, nil)

        if reason == :normal do
          {:noreply, socket}
        else
          Logger.error("reset task died: #{inspect(reason)}")
          {:noreply, put_status(socket, :error)}
        end

      socket.assigns.n1_task == ref ->
        socket = assign_n1_task(socket, :reset)

        if reason == :normal do
          {:noreply, socket}
        else
          Logger.error("N-1 screening task died: #{inspect(reason)}")
          {:noreply, assign_n1(socket, :error)}
        end

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Private

  defp inject_failure(socket, type, id) do
    # UI-H1: raw client id -- validate, ignore garbage instead of crashing
    case parse_int(id) do
      nil ->
        {:noreply, socket}

      component_id ->
        # CAS-5 / UI-C3: a failed server start must surface as an error
        # state, not an eternal spinner.
        case ensure_sim_server_for(socket, {type, component_id}) do
          {:ok, socket} ->
            socket =
              socket
              |> assign(:cascade_active, true)
              |> put_status(:solving)
              # UI-M2: each injection is a new disturbance; the nadir
              # tracking starts fresh at nominal frequency.
              |> update(:system_metrics, &rearm_frequency/1)
              # UIW-3: the LODF screen was computed for the pre-trip
              # injection vector, so it is advisory the instant a component
              # leaves the network.
              |> assign(:n1_stale, true)
              |> start_trip_task(type, component_id)

            {:noreply, socket}

          {:error, reason, socket} ->
            Logger.error("simulation server start failed: #{inspect(reason)}")
            {:noreply, fail_simulation(socket)}
        end
    end
  end

  defp launch_n1_screening(socket) do
    sim_id = socket.assigns.sim_id
    # self() inside the Task closure would be the Task's pid, not this LiveView
    lv = self()
    interconnection = socket.assigns.interconnection
    hour = socket.assigns.selected_hour
    budget = n1_budget_ms(interconnection)

    # UI-M11: the screening task is monitored and deadlined -- a dead or hung
    # task must never leave the button stuck at "Scanning...".
    {:ok, task_pid} =
      Task.start(fn ->
        result =
          try do
            with {:ok, _pid} <- ensure_sim_server(sim_id, interconnection, hour) do
              sim_id |> SimulationServer.screening_snapshot() |> screen_snapshot()
            end
          catch
            :exit, reason -> {:error, reason}
          end

        send(lv, {:n1_screening_done, result})
      end)

    ref = Process.monitor(task_pid)
    deadline = Process.send_after(self(), {:n1_screening_timeout, ref}, budget)

    {:noreply, assign_n1_task(socket, {:running, ref, task_pid, deadline})}
  end

  # UI-H1: only "all" or a positive integer are meaningful interconnection
  # scopes; anything else (crafted URLs) falls back to "all" instead of
  # crashing the mount/patch.
  defp validate_interconnection(nil), do: "all"
  defp validate_interconnection("all"), do: "all"

  defp validate_interconnection(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {id, ""} when id > 0 -> Integer.to_string(id)
      _ -> "all"
    end
  end

  defp validate_interconnection(_), do: "all"

  # CAS-7 / UI-M6: the session used to be pinned forever to the scope of the
  # FIRST server start ("all" mode resolves it from the first-clicked
  # component); a later click in another interconnection was rejected until
  # page reload. Track the running server's scope and restart on mismatch.
  defp ensure_sim_server_for(socket, component) do
    sim_id = socket.assigns.sim_id

    desired =
      case desired_scope(socket.assigns.interconnection, component) do
        :keep -> socket.assigns.server_scope
        scope -> scope
      end

    case Registry.lookup(PowerModel.SimulationRegistry, sim_id) do
      [{pid, _}] ->
        if desired == socket.assigns.server_scope do
          {:ok, monitor_sim_server(socket, pid)}
        else
          socket = demonitor_sim_server(socket)
          DynamicSupervisor.terminate_child(PowerModel.SimulationSupervisor, pid)
          start_sim_server(socket, desired)
        end

      [] ->
        start_sim_server(socket, desired)
    end
  end

  defp desired_scope("all", component) do
    case resolve_interconnection(component) do
      nil -> :keep
      id -> id
    end
  end

  defp desired_scope(interconnection, _component) do
    case parse_int(interconnection) do
      nil -> :keep
      id -> id
    end
  end

  defp start_sim_server(socket, scope) do
    opts = [
      sim_id: socket.assigns.sim_id,
      interconnection_id: scope,
      hour: socket.assigns.selected_hour
    ]

    # A newly started server counts from epoch zero, and this session has no
    # way to know where an already-started one is -- either way the epochs it
    # remembers belong to a different server (UI-M20).
    socket = assign(socket, :sim_epoch, nil)

    case DynamicSupervisor.start_child(PowerModel.SimulationSupervisor, {SimulationServer, opts}) do
      {:ok, pid} ->
        {:ok, socket |> assign(:server_scope, scope) |> monitor_sim_server(pid)}

      {:error, {:already_started, pid}} ->
        {:ok, socket |> assign(:server_scope, scope) |> monitor_sim_server(pid)}

      {:error, reason} ->
        {:error, reason, assign(socket, :server_scope, nil)}
    end
  end

  # Non-socket variant for use from task processes (N-1 screening): only
  # guarantees existence, never restarts on scope mismatch.
  defp ensure_sim_server(sim_id, interconnection, hour) do
    case Registry.lookup(PowerModel.SimulationRegistry, sim_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        scope = if interconnection == "all", do: nil, else: parse_int(interconnection)
        opts = [sim_id: sim_id, interconnection_id: scope, hour: hour]

        case DynamicSupervisor.start_child(
               PowerModel.SimulationSupervisor,
               {SimulationServer, opts}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp monitor_sim_server(socket, pid) do
    case socket.assigns.sim_server do
      {^pid, _ref} -> socket
      _ -> assign(socket, :sim_server, {pid, Process.monitor(pid)})
    end
  end

  defp demonitor_sim_server(socket) do
    case socket.assigns.sim_server do
      {_pid, ref} ->
        Process.demonitor(ref, [:flush])
        assign(socket, :sim_server, nil)

      _ ->
        socket
    end
  end

  # CAS-5: the sim server vanished OUT FROM UNDER the session (crash or idle
  # reap -- intentional stops demonitor first). The client's painted state no
  # longer corresponds to any server; reset it rather than silently desync.
  defp handle_sim_server_down(socket, reason) do
    socket =
      socket
      |> assign(:sim_server, nil)
      |> assign(:server_scope, nil)
      # The epoch counter belonged to the server that just died; the next one
      # starts from zero and nothing may be compared across them.
      |> assign(:sim_epoch, nil)
      |> assign(:cascade_steps, [])
      |> assign_cascade_events(:reset)
      |> assign(:cascade_active, false)
      |> assign(:system_metrics, initial_metrics())
      # UI-M20: a sweep still running against the dead server's snapshot must
      # not repopulate the panel the reset below just cleared.
      |> assign_n1_task(:cancel)
      |> assign_n1(:reset)
      |> push_event("reset_grid", %{})

    case reason do
      normal when normal in [:normal, :shutdown] ->
        {:noreply, put_status(socket, :idle)}

      {:shutdown, _} ->
        {:noreply, put_status(socket, :idle)}

      other ->
        Logger.error("simulation server crashed: #{inspect(other)}")
        {:noreply, put_status(socket, :error)}
    end
  end

  defp start_trip_task(socket, type, component_id) do
    sim_id = socket.assigns.sim_id
    lv = self()

    {:ok, task_pid} =
      Task.start(fn ->
        result =
          try do
            case type do
              "transmission_line" -> SimulationServer.trip_branch(sim_id, component_id)
              "generator" -> SimulationServer.trip_generator(sim_id, component_id)
              "transformer" -> SimulationServer.trip_transformer(sim_id, component_id)
            end
          catch
            :exit, reason -> {:error, {:exit, reason}}
          end

        case result do
          {:error, reason} when reason in [:not_in_network, :already_tripped] ->
            send(lv, {:trip_rejected, reason, type, component_id})

          {:error, reason} ->
            send(lv, {:trip_failed, reason, type, component_id})

          _ ->
            :ok
        end
      end)

    assign(socket, :trip_task, Process.monitor(task_pid))
  end

  # CAS-3: once a cascade is classified (Stable/Unstable) the late-arriving
  # AC refinement must not overwrite the classification with "AC Converged";
  # its flows/metrics still land. A new trip or reset re-arms the status.
  # The badge's two halves always move together: a status change that left a
  # stale sub-label behind would caption the new state with the old one's
  # caveat.
  defp put_status(socket, status, note \\ nil) do
    socket |> assign(:solver_status, status) |> assign(:solver_note, note)
  end

  @terminal_statuses [
    :stable,
    :stable_shed,
    :unstable,
    :collapsed,
    :truncated,
    :solve_failed
  ]

  defp put_solver_result_status(socket, status) do
    if socket.assigns.solver_status in @terminal_statuses do
      socket
    else
      put_status(socket, status)
    end
  end

  # UI-C3: shared error path -- leave the cascade state (client included) and
  # show an error instead of the eternal spinner.
  defp fail_simulation(socket) do
    socket
    |> assign(:cascade_active, false)
    |> put_status(:error)
    |> push_event("cascade_done", %{stable: false})
  end

  # ---------------------------------------------------------------------------
  # N-1 contingency screening (UIW-2 / UIW-3)
  # ---------------------------------------------------------------------------

  # Eastern's sweep alone measured 63.0-65.5 s; the national scope pays for a
  # partition and a base solve of the whole snapshot first.
  defp n1_budget_ms("all"), do: @n1_budget_national_ms
  defp n1_budget_ms(_scope), do: @n1_budget_scoped_ms

  defp n1_hint("all"), do: "Screening the largest island — up to ~2 minutes"
  defp n1_hint(_scope), do: "Screening every branch — up to ~1 minute"

  @doc false
  # Screen one electrical island, which is what LODF requires: `LODF.init/3`
  # refuses a disconnected graph outright (`{:error, {:disconnected, n}}`), and
  # the default "all" scope IS disconnected -- it is the three asynchronous
  # interconnections, joined only by DC ties, which no linear AC sensitivity
  # crosses. Handing that straight to the sweep would put the panel in its
  # error state on the first click of a fresh session, forever. So the sweep
  # runs on the LARGEST island and the panel says how much of the snapshot
  # that was.
  #
  # The session's own DC solution is reused only when the snapshot IS one
  # island -- it is a per-island merge, and `screening_snapshot/1` documents
  # that passing it asserts exactly that.
  def screen_snapshot(%{snapshot: snapshot} = session) do
    case Partition.split(snapshot) do
      {[], _dead} ->
        {:error, :no_solvable_island}

      {islands, dead} ->
        island = Enum.max_by(islands, &length(&1.buses))
        opts = [base_mva: session.base_mva, limit: @n1_ranked_limit]

        # The base solve is reusable only for a single-island snapshot, which
        # is the ordinary case for ONE interconnection. It is never the case
        # for the "all" scope: `Grid.get_full_grid_snapshot/1` keeps every
        # component of at least 200 buses, so the national snapshot is the
        # three asynchronous systems (measured: 3 islands, 51,713 of 74,629
        # buses in the largest). Cascade islanding produces the same shape.
        result =
          if islands == [island] and dead == [] and session.dc_solution != nil do
            ContingencyScreening.run(island, session.dc_solution, opts)
          else
            ContingencyScreening.run(island, opts)
          end

        # UIW-2 (verifier): run/2 and run/3 both answer {:ok, result}. The
        # tuple has to come off here or the panel renders a two-element list.
        with {:ok, screen} <- result do
          {:ok,
           screen
           # UI-M20: the topology generation this ranking describes. The
           # session compares it with the epoch the engine has reached, so a
           # sweep that reports after a trip is presented as advisory instead
           # of as the current picture.
           |> Map.put(:epoch, session[:epoch])
           |> Map.put(:scope, %{
             # Dead islands count: an islanded fragment with no generator is
             # still part of the network the user is looking at, and leaving
             # it out of the denominator would overstate the coverage.
             islands: length(islands) + length(dead),
             buses_screened: length(island.buses),
             buses_total: length(snapshot.buses)
           })}
        end
    end
  end

  def screen_snapshot(_session), do: {:error, :no_snapshot}

  # The in-flight sweep's three handles, moved together so none can be left
  # behind: the monitor ref (also the deadline's identity), the task pid, and
  # the deadline timer.
  #
  #   :reset   the task is gone or was never armed -- drop the handles.
  #   :cancel  the task is still running and its answer is no longer wanted.
  #            Killing it is safe: `screening_snapshot/1` is a read and the
  #            sweep has no side effects on the server.
  defp assign_n1_task(socket, mode) when mode in [:reset, :cancel] do
    task_pid = socket.assigns[:n1_task_pid]

    if ref = socket.assigns[:n1_task], do: Process.demonitor(ref, [:flush])
    if timer = socket.assigns[:n1_deadline], do: Process.cancel_timer(timer)

    socket =
      socket
      |> assign(:n1_task, nil)
      |> assign(:n1_task_pid, nil)
      |> assign(:n1_deadline, nil)

    if mode == :cancel do
      if task_pid, do: Process.exit(task_pid, :kill)
      # The kill stops a result being SENT; a result already in this mailbox
      # would still be delivered after the cancel and repopulate the panel the
      # caller just cleared. Drop those too -- they rank a network that no
      # longer exists (UI-M20).
      flush_n1_results()
      # Nothing is running and nothing will report: the button must not be
      # left at "Scanning..." waiting for a result that was cancelled.
      assign(socket, :n1_screening, false)
    else
      socket
    end
  end

  defp assign_n1_task(socket, {:running, ref, pid, deadline}) do
    socket
    |> assign(:n1_task, ref)
    |> assign(:n1_task_pid, pid)
    |> assign(:n1_deadline, deadline)
  end

  defp flush_n1_results do
    receive do
      {:n1_screening_done, _result} -> flush_n1_results()
    after
      0 -> :ok
    end
  end

  defp assign_n1(socket, :reset) do
    socket
    |> assign(:n1_screening, false)
    |> assign(:n1_error, false)
    |> assign(:n1_result, nil)
    |> assign(:n1_stale, false)
    |> assign(:n1_hint, nil)
  end

  defp assign_n1(socket, :error) do
    socket
    |> assign(:n1_screening, false)
    |> assign(:n1_error, true)
    |> assign(:n1_hint, nil)
  end

  defp assign_n1(socket, {:result, screen}) do
    socket
    |> assign(:n1_screening, false)
    |> assign(:n1_error, false)
    |> assign(:n1_result, screen)
    # UI-M20: this used to clear staleness unconditionally, so a sweep that
    # reported AFTER a mid-sweep trip erased the advisory that trip had just
    # raised -- presenting a pre-trip LODF linearisation as current. Both
    # halves are needed: the flag catches an invalidation this view saw and
    # the engine has not finished reporting, and the epoch catches a result
    # whose snapshot predates a change the flag no longer remembers.
    |> assign(
      :n1_stale,
      socket.assigns.n1_stale or screen_stale?(screen, socket.assigns.sim_epoch)
    )
    |> assign(:n1_hint, nil)
  end

  # `<`, not `!=`: a sweep may legitimately be NEWER than the last epoch this
  # view has been told about (the snapshot is taken inside the task, and
  # `cascade_done` is what delivers the epoch). Only an older one is stale.
  # Either side unknown means no claim -- a fresh or restarted server has no
  # epoch history to compare against, and the flag alone governs there.
  defp screen_stale?(%{epoch: screen_epoch}, sim_epoch)
       when is_integer(screen_epoch) and is_integer(sim_epoch),
       do: screen_epoch < sim_epoch

  defp screen_stale?(_screen, _sim_epoch), do: false

  # UI-M20: the engine's topology generation, as reported by the payloads that
  # carry it. A payload from a server that predates the field leaves the last
  # known value alone rather than blanking it -- absence is no information.
  defp track_sim_epoch(socket, payload) do
    case payload[:epoch] do
      epoch when is_integer(epoch) -> assign(socket, :sim_epoch, epoch)
      _ -> socket
    end
  end

  # UI-M3: only component trips count toward the Tripped metric
  defp step_component_trips(payload) do
    length(payload[:tripped_line_ids] || []) +
      length(payload[:tripped_transformer_ids] || []) +
      length(payload[:tripped_generator_ids] || [])
  end

  # UIW-5. Frequency is TWO numbers, and the bug this closes is reporting one
  # as the other: the panel latched the nadir and never let go, so a cascade
  # that AGC had walked back to 60.00 Hz kept showing 59.21 in critical red
  # forever. `frequency_hz` is where the system is now; `frequency_nadir_hz`
  # is the deepest dip on the way there, and it is the number that explains
  # what tripped and what was shed.
  #
  # Both sources feed it. The engine's own `:frequency` (load-weighted across
  # islands) is authoritative when present; the shed events' `frequency_nadir`
  # is kept because it is the only nadir a manual-trip step carries, and
  # because the shed AGGREGATE carries the group MINIMUM precisely so this
  # running minimum survives aggregation.
  defp track_frequency(metrics, payload) do
    metrics
    |> apply_frequency(payload[:frequency])
    |> apply_shed_nadir(payload[:trips])
    |> record_frequency_point(payload[:simulated_time])
  end

  defp apply_frequency(metrics, %{} = frequency) do
    f_hz = number_or(frequency[:f_hz], metrics.frequency_hz)
    nadir = number_or(frequency[:nadir_hz], metrics.frequency_nadir_hz)

    %{metrics | frequency_hz: f_hz, frequency_nadir_hz: min(metrics.frequency_nadir_hz, nadir)}
  end

  defp apply_frequency(metrics, _absent), do: metrics

  defp apply_shed_nadir(metrics, trips) when is_list(trips) do
    nadir =
      trips
      |> Enum.map(fn trip -> trip |> Map.get(:details) |> nadir_from_details() end)
      |> Enum.filter(&is_number/1)
      |> Enum.min(fn -> nil end)

    case nadir do
      nil -> metrics
      hz -> %{metrics | frequency_nadir_hz: min(metrics.frequency_nadir_hz, hz * 1.0)}
    end
  end

  defp apply_shed_nadir(metrics, _trips), do: metrics

  # A bounded trace for the sparkline. Simulated time is the x axis when the
  # step carries it; steps without one fall in at their arrival order.
  @freq_history_points 120

  defp record_frequency_point(metrics, t) do
    point = {number_or(t, 0.0), metrics.frequency_hz}
    history = Enum.take(metrics.freq_history ++ [point], -@freq_history_points)
    %{metrics | freq_history: history}
  end

  defp rearm_frequency(metrics) do
    %{metrics | frequency_hz: 60.0, frequency_nadir_hz: 60.0, freq_history: []}
  end

  defp number_or(v, _default) when is_number(v), do: v * 1.0
  defp number_or(_v, default), do: default

  defp nadir_from_details(%{} = details), do: Map.get(details, :frequency_nadir)
  defp nadir_from_details(_), do: nil

  # Contract rule: absence means "no information", never zero. A step whose
  # voltage layer never ran carries no :voltage_layer key, and overwriting the
  # last real reading with a zeroed one would report "no undervoltage" for a
  # cascade that never looked.
  defp merge_present(metrics, _key, nil), do: metrics
  defp merge_present(metrics, _key, []), do: metrics
  defp merge_present(metrics, key, value), do: Map.put(metrics, key, value)

  # Three independent facts arrive on `cascade_done`, and the badge has to
  # combine them without letting any one of them hide another:
  #
  #   :reason   why the run STOPPED     -- :settled | :budget_exhausted | :solve_failed
  #   :outcome  what it LEFT STANDING   -- :collapsed | :degraded | :intact
  #   :stable   the engine's own flag
  #
  # The precedence below is not a styling choice. Each rule is about which
  # statement we are entitled to make.
  #
  # 1. A failed solve outranks everything, INCLUDING a collapse. `outcome/1`
  #    is computed entirely from `balance/1`, which is downstream of the solve
  #    that failed -- so on :solve_failed the collapse verdict is derived from
  #    numbers the engine has already declared untrustworthy. "Collapsed"
  #    there would assert we know the grid went down, when what we know is
  #    that we stopped being able to compute. It also buries the one fact the
  #    operator needs. So: no outcome, not even as a sub-label.
  # 2. A collapse outranks how the run ended. :settled and :budget_exhausted
  #    both leave the balance trustworthy, so a collapse measured from it is
  #    real, and "Unstable" understates a grid serving under half its load.
  #    Truncation survives as the sub-label rather than being dropped -- a
  #    cascade cut off mid-collapse was still getting worse.
  # 3. `stable: true` is deliberately NOT allowed to produce "Stable" when the
  #    outcome says otherwise. The reference cascade ends `stable: true,
  #    reason: :settled` while serving 3.6 MW of 42,653 MW; that pairing is
  #    what this whole escalation exists to stop rendering as "Stable".
  #
  # An absent or unrecognised outcome falls back to the reason-only reading,
  # so an older frame or a value added later degrades instead of crashing.
  # `:outcome` is `:unknown` on exactly the solve-failed runs, where the
  # engine withholds the classification for the reason in rule 1 -- that
  # lands on the first clause and never reaches the fallback. The fallback
  # still matters: it is what renders a payload from a server that predates
  # the field, which is what a rolling restart produces.
  defp cascade_status(:solve_failed, _outcome, _stable), do: {:solve_failed, nil}
  defp cascade_status(reason, :collapsed, _stable), do: {:collapsed, truncation_note(reason)}
  defp cascade_status(:budget_exhausted, outcome, _stable), do: {:truncated, shed_note(outcome)}
  defp cascade_status(_reason, :degraded, _stable), do: {:stable_shed, nil}
  defp cascade_status(_reason, :intact, true), do: {:stable, nil}
  defp cascade_status(_reason, :intact, false), do: {:unstable, nil}
  defp cascade_status(_reason, _outcome, true), do: {:stable, nil}
  defp cascade_status(_reason, _outcome, false), do: {:unstable, nil}

  defp truncation_note(:budget_exhausted), do: "step budget"
  defp truncation_note(_reason), do: nil

  defp shed_note(:degraded), do: "load shed"
  defp shed_note(_outcome), do: nil

  # Changing the demand hour invalidates the running simulation's snapshot;
  # terminate it so the next failure injection rebuilds at the new hour.
  # Re-selecting the SAME hour is a no-op (UI-M5).
  defp apply_selected_hour(socket, selected_hour) do
    if same_hour?(socket.assigns.selected_hour, selected_hour) do
      socket
    else
      socket = stop_sim_server(socket)

      socket
      |> assign(:selected_hour, selected_hour)
      |> assign(:cascade_steps, [])
      |> assign_cascade_events(:reset)
      |> assign(:cascade_active, false)
      |> assign(:selected_component, nil)
      |> put_status(:idle)
      |> assign(:system_metrics, initial_metrics())
      # A new hour is a new injection vector, and LODF sensitivities are a
      # linearisation about the old one -- the ranking is advisory now.
      |> assign(:n1_stale, true)
      |> push_event("reset_grid", %{})
      |> push_event("deselect_highlight", %{})
    end
  end

  defp same_hour?(nil, nil), do: true
  defp same_hour?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq
  defp same_hour?(_, _), do: false

  defp stop_sim_server(socket) do
    socket = demonitor_sim_server(socket)

    case Registry.lookup(PowerModel.SimulationRegistry, socket.assigns.sim_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(PowerModel.SimulationSupervisor, pid)
      [] -> :ok
    end

    # A sweep still running against the server being torn down would come back
    # as a :noproc error and put the panel in its failure state for what is an
    # ordinary hour change (UI-M20).
    socket
    |> assign_n1_task(:cancel)
    |> assign(:sim_epoch, nil)
    |> assign(:server_scope, nil)
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

  defp resolve_interconnection({"transformer", xfmr_id}) do
    import Ecto.Query

    PowerModel.Repo.one(
      from t in PowerModel.Grid.Transformer,
        join: b in PowerModel.Grid.Bus,
        on: t.from_bus_id == b.id,
        where: t.id == ^xfmr_id,
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
      # UIW-3/UIW-6: rooftop PV that tripped off is demand the wire no longer
      # sees. Without it the displayed served + shed + blackout exceeds the
      # displayed demand by exactly the BTM amount and nothing on the panel
      # explains the gap.
      btm_tripped_mw: 0.0,
      btm_trip_breakdown: nil,
      frequency_hz: 60.0,
      frequency_nadir_hz: 60.0,
      freq_history: [],
      voltage_layer: nil,
      agc: [],
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
      %{
        m
        | total_gen_mw: payload[:total_gen_mw] || m.total_gen_mw,
          total_load_mw: payload[:total_load_mw] || m.total_load_mw,
          total_loss_mw: payload[:total_loss_mw] || m.total_loss_mw,
          mismatch_mw: payload[:mismatch_mw] || m.mismatch_mw,
          overload: payload[:overload_summary] || m.overload
      }
    end)
  end

  defp merge_balance(metrics, nil), do: metrics

  defp merge_balance(metrics, balance) do
    %{
      metrics
      | demand_mw: balance[:original_load_mw] || metrics.demand_mw,
        served_mw: balance[:served_load_mw] || metrics.served_mw,
        shed_mw: balance[:shed_load_mw] || metrics.shed_mw,
        blackout_mw: balance[:blackout_load_mw] || metrics.blackout_mw,
        # The conservation identity the engine holds to is
        # served + shed + blackout == original + btm_tripped; dropping the
        # last term is what broke it on the display side.
        btm_tripped_mw: balance[:btm_tripped_mw] || metrics.btm_tripped_mw
    }
  end

  defp solver_status_class(:idle), do: "status-idle"
  defp solver_status_class(:solving), do: "status-solving"
  defp solver_status_class(:resetting), do: "status-solving"
  defp solver_status_class(:dc_solved), do: "status-dc"
  defp solver_status_class(:ac_solved), do: "status-ac"
  defp solver_status_class(:ac_partial), do: "status-ac"
  defp solver_status_class(:stable), do: "status-stable"
  defp solver_status_class(:stable_shed), do: "status-degraded"
  defp solver_status_class(:unstable), do: "status-rejected"
  defp solver_status_class(:collapsed), do: "status-collapsed"
  defp solver_status_class(:truncated), do: "status-truncated"
  defp solver_status_class(:solve_failed), do: "status-rejected"
  defp solver_status_class(:error), do: "status-rejected"
  defp solver_status_class(:not_in_network), do: "status-rejected"
  defp solver_status_class(:already_tripped), do: "status-rejected"
  defp solver_status_class(_), do: "status-idle"

  defp solver_status_text(:idle), do: "Idle"
  defp solver_status_text(:solving), do: "Solving..."
  defp solver_status_text(:resetting), do: "Resetting..."
  defp solver_status_text(:dc_solved), do: "DC Solved"
  defp solver_status_text(:ac_solved), do: "AC Converged"
  # UIW-4: the cascade's QSS-AC covers the islands that converged and says
  # nothing about the rest, so this is never "AC Converged".
  defp solver_status_text(:ac_partial), do: "AC (partial)"
  defp solver_status_text(:stable), do: "Stable"
  # Settled, and it kept the lights on by giving some of them up.
  defp solver_status_text(:stable_shed), do: "Stable (load shed)"
  defp solver_status_text(:unstable), do: "Unstable"
  # Under half of standing demand is being served. "Unstable" does not cover
  # a grid in that state, whatever the engine's own stable flag says.
  defp solver_status_text(:collapsed), do: "Collapsed"
  # The cascade was still tripping when it ran out of step budget. It is NOT
  # a settled collapse and must not be read as one.
  defp solver_status_text(:truncated), do: "Unstable (step budget)"
  defp solver_status_text(:solve_failed), do: "Solve failed"
  defp solver_status_text(:error), do: "Simulation failed"
  defp solver_status_text(:not_in_network), do: "Not in simulated network"
  defp solver_status_text(:already_tripped), do: "Already tripped"
  defp solver_status_text(_), do: "Idle"

  # UI-L6: codes mirror the client's FUEL_COLORS table (color_scales.js)
  defp fuel_type_name(nil), do: nil
  defp fuel_type_name(0), do: "Unknown"
  defp fuel_type_name(1), do: "Natural Gas"
  defp fuel_type_name(2), do: "Coal"
  defp fuel_type_name(3), do: "Coal"
  defp fuel_type_name(4), do: "Nuclear"
  defp fuel_type_name(5), do: "Hydro"
  defp fuel_type_name(6), do: "Wind"
  defp fuel_type_name(7), do: "Solar"
  defp fuel_type_name(8), do: "Oil (Distillate)"
  defp fuel_type_name(9), do: "Oil (Residual)"
  defp fuel_type_name(10), do: "Wood/Biomass"
  defp fuel_type_name(11), do: "Geothermal"
  defp fuel_type_name(12), do: "Import (Intl)"
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
    |> Enum.map(fn {h, mw} ->
      "#{Float.round(chart_x(h), 1)},#{Float.round(chart_y(mw, y_max), 1)}"
    end)
    |> Enum.join(" ")
  end

  defp format_gw(mw), do: "#{Float.round(mw / 1000.0, 1)} GW"

  attr :utilization, :map, required: true

  defp utilization_panel(assigns) do
    ~H"""
    <div class="util-panel">
      <div class="util-header">
        <h3>Grid Utilization — {Calendar.strftime(@utilization.date, "%a, %b %d %Y")} (UTC)</h3>
        <button phx-click="toggle_utilization" class="close-btn">&times;</button>
      </div>

      <div class="util-controls">
        <form phx-change="set_util_date">
          <input type="date" name="date" value={Date.to_iso8601(@utilization.date)} class="hour-date" />
        </form>
        <button phx-click="util_peak_day" class="util-peak-btn">Peak day</button>
      </div>

      <%!-- UI-L16: the stats below carry the same numbers in text, but the
            chart itself still needs a name rather than announcing as a bare
            graphic. --%>
      <svg
        viewBox={"0 0 #{chart_w()} #{chart_h()}"}
        class="util-chart"
        preserveAspectRatio="xMidYMid meet"
        role="img"
        aria-labelledby="util-chart-title"
      >
        <title id="util-chart-title">
          Hourly demand against modeled capacity per interconnection, {Calendar.strftime(
            @utilization.date,
            "%b %d %Y"
          )} UTC
        </title>
        <%!-- horizontal gridlines at quarter intervals --%>
        <%= for frac <- [0.25, 0.5, 0.75, 1.0] do %>
          <line
            x1={pad_l()}
            x2={chart_w() - pad_r()}
            y1={Float.round(chart_y(@utilization.y_max * frac, @utilization.y_max), 1)}
            y2={Float.round(chart_y(@utilization.y_max * frac, @utilization.y_max), 1)}
            stroke="rgba(120,120,140,0.18)"
            stroke-width="1"
          />
          <text
            x={pad_l() - 6}
            y={Float.round(chart_y(@utilization.y_max * frac, @utilization.y_max) + 3, 1)}
            class="util-axis-label"
            text-anchor="end"
          >
            {format_gw(@utilization.y_max * frac)}
          </text>
        <% end %>

        <%!-- x axis labels --%>
        <%= for h <- [0, 6, 12, 18, 23] do %>
          <text
            x={Float.round(chart_x(h), 1)}
            y={chart_h() - 8}
            class="util-axis-label"
            text-anchor="middle"
          >
            {String.pad_leading("#{h}", 2, "0")}:00
          </text>
        <% end %>

        <%!-- capacity reference lines (dashed) + demand curves --%>
        <%= for s <- @utilization.series do %>
          <%= if s.capacity_mw > 0 do %>
            <line
              x1={pad_l()}
              x2={chart_w() - pad_r()}
              y1={Float.round(chart_y(s.capacity_mw, @utilization.y_max), 1)}
              y2={Float.round(chart_y(s.capacity_mw, @utilization.y_max), 1)}
              stroke={s.color}
              stroke-width="1"
              stroke-dasharray="5,4"
              opacity="0.55"
            />
          <% end %>
          <polyline
            points={demand_points(s.hours, @utilization.y_max)}
            fill="none"
            stroke={s.color}
            stroke-width="2"
            stroke-linejoin="round"
            stroke-linecap="round"
          />
        <% end %>
      </svg>

      <div class="util-stats">
        <%= for s <- @utilization.series do %>
          <div class="util-stat" style={"border-left: 3px solid #{s.color};"}>
            <div class="util-stat-name">{s.name}</div>
            <div class="util-stat-row">
              <span>Capacity</span><span><%= format_gw(s.capacity_mw) %></span>
            </div>
            <div class="util-stat-row">
              <span>Peak</span>
              <span>{format_gw(s.peak_mw)} @ {String.pad_leading("#{s.peak_hour}", 2, "0")}:00</span>
            </div>
            <div class="util-stat-row">
              <span>Trough</span>
              <span>{format_gw(s.min_mw)} @ {String.pad_leading("#{s.min_hour}", 2, "0")}:00</span>
            </div>
            <div class="util-stat-row util-stat-em">
              <span>Peak utilization</span>
              <span>{Float.round(s.peak_util_pct, 1)}%</span>
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

  # UI-L7: keys and colors mirror the client's VOLTAGE_COLORS classes
  # (color_scales.js) -- a class missing here is untoggleable on the map.
  @voltage_legend [
    {"69", "69 kV", "rgb(100, 149, 237)"},
    {"115", "115 kV", "rgb(70, 130, 180)"},
    {"138", "138 kV", "rgb(64, 224, 208)"},
    {"161", "161 kV", "rgb(0, 206, 209)"},
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

  # UI-L7: mirrors the client's datacenter type table (datacenters_layer.js)
  @datacenter_legend [
    {"hyperscale", "Hyperscale", "rgb(80, 200, 255)"},
    {"colocation", "Colocation", "rgb(180, 140, 255)"},
    {"ai_training", "AI Training", "rgb(255, 120, 200)"},
    {"enterprise", "Enterprise", "rgb(160, 180, 200)"},
    {"crypto", "Crypto", "rgb(255, 190, 80)"}
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
      {render_slot(@inner_block)}
      <span>{@label}</span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Affected-components feed (UIW-5)
  # ---------------------------------------------------------------------------
  #
  # The panel used to re-flat_map every event of every step on EVERY render,
  # and then show `Enum.take(events, 50)` -- the OLDEST fifty. At collapse
  # scale that is both the expensive way to build the list and the wrong half
  # of it: the terminal-phase voltage, UVLS and ride-through events, which are
  # the ones worth reading, could never appear.
  #
  # The feed is now maintained incrementally, NEWEST FIRST, and bounded. The
  # true event total is tracked separately from the list, because the payload's
  # `trips` is a panel VIEW (aggregated and capped by the server) while
  # `trip_count` is the real number of events the step emitted.
  @event_feed_limit 200

  defp assign_cascade_events(socket, :reset) do
    socket
    |> assign(:cascade_events, [])
    |> assign(:cascade_event_total, 0)
    |> assign(:cascade_events_omitted, 0)
  end

  defp assign_cascade_events(socket, {:step, payload}) do
    trips = if is_list(payload[:trips]), do: payload[:trips], else: []
    step = payload[:step]

    newest =
      trips
      |> Enum.reverse()
      |> Enum.map(&Map.put(&1, :step, step))

    feed = Enum.take(newest ++ socket.assigns.cascade_events, @event_feed_limit)

    # `trip_count` is the step's TRUE event count; `trips` is the panel view.
    # At collapse scale they differ by thousands and the header must report
    # the former (UI-2's contract note).
    total = socket.assigns.cascade_event_total + (payload[:trip_count] || length(trips))

    # UI-L17: the server itemises at most 200 non-shed events per step
    # (`panel_trips/2`) and reports how many it withheld. That number was
    # computed, shipped and read by nothing, so the cap was invisible: the
    # feed's shortfall against the total read as a scroll limit when part of
    # it is data the browser never received. The cap reserves a slot for the
    # first event of every CAUSE, so no mechanism is hidden -- only further
    # instances of causes already shown.
    omitted = socket.assigns.cascade_events_omitted + (payload[:trips_omitted] || 0)

    socket
    |> assign(:cascade_events, feed)
    |> assign(:cascade_event_total, total)
    |> assign(:cascade_events_omitted, omitted)
  end
end
