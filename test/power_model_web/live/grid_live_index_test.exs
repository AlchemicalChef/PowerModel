defmodule PowerModelWeb.GridLiveIndexTest do
  @moduledoc """
  LiveView coverage for the round-3 engine package: param validation (UI-H1),
  catch-all events (UI-M13), distinct cascade end states (CAS-3, UI-C1),
  reset symmetry (UI-M14, UI-C2), per-step metrics (UI-M2, UI-M3),
  position-based timeline scrubbing (UI-H3), incomplete hour selections
  (UI-M5), error surfacing (CAS-5, UI-C3), and legend completeness (UI-L7).
  """

  use PowerModelWeb.ConnCase, async: false

  @moduletag :db

  import Phoenix.LiveViewTest

  alias PowerModel.Repo
  alias PowerModel.Grid.{Bus, Generator, Load, TransmissionLine}

  setup do
    # Sim servers started by the view must not outlive the test (they hold DB
    # sandbox references).
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(PowerModel.SimulationSupervisor),
          is_pid(pid) do
        DynamicSupervisor.terminate_child(PowerModel.SimulationSupervisor, pid)
      end
    end)

    :ok
  end

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  # A self-contained 2-bus island in its own interconnection.
  defp build_island(name, lon) do
    ic = Repo.insert!(%PowerModel.Grid.Interconnection{name: name})

    bus1 =
      Repo.insert!(%Bus{
        bus_type: 3,
        base_kv: 138.0,
        interconnection_id: ic.id,
        coordinates: point(lon, 33.4)
      })

    bus2 =
      Repo.insert!(%Bus{
        bus_type: 1,
        base_kv: 138.0,
        interconnection_id: ic.id,
        coordinates: point(lon + 0.1, 33.5)
      })

    line =
      Repo.insert!(%TransmissionLine{
        voltage_kv: 138.0,
        from_bus_id: bus1.id,
        to_bus_id: bus2.id,
        x_pu: 0.1,
        rating_a_mva: 200.0,
        status: "in_service"
      })

    Repo.insert!(%Generator{p_max_mw: 100.0, bus_id: bus1.id, status: "in_service"})
    Repo.insert!(%Load{p_mw: 60.0, q_mvar: 18.0, bus_id: bus2.id, status: "in_service"})

    %{interconnection: ic, line: line}
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Occupies the sim server's registry slot with a process that ACCEPTS the
  # trip call and never replies, pinning the LiveView in its "cascade running"
  # state for as long as the test needs. Reports each call back to the test so
  # a SECOND injection is observable.
  defp hang_sim_server(sim_id) do
    test_pid = self()

    spawn_link(fn ->
      {:ok, _} = Registry.register(PowerModel.SimulationRegistry, sim_id, nil)
      send(test_pid, :fake_server_up)
      hang_loop(test_pid)
    end)

    assert_receive :fake_server_up
    :ok
  end

  defp hang_loop(test_pid) do
    receive do
      {:"$gen_call", _from, {:trip_branch, id}} ->
        send(test_pid, {:trip_call, id})
        hang_loop(test_pid)

      _other ->
        hang_loop(test_pid)
    end
  end

  defp status(view) do
    view
    |> render()
    |> then(fn html ->
      case Regex.run(~r/id="solver-badge" data-status="([^"]+)"/, html) do
        [_, s] -> s
        _ -> nil
      end
    end)
  end

  # Every state a finished cascade can settle on. This test island is two
  # buses with one line, so tripping that line strands its only load and the
  # honest verdict is "collapsed" -- these tests care that the cascade REACHED
  # a terminal state, not which one.
  @terminal_statuses ~w(stable stable_shed unstable collapsed truncated solve_failed)

  defp finished?(view), do: status(view) in @terminal_statuses

  defp await(fun, timeout_ms \\ 8_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(fun, deadline)
  end

  defp do_await(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(50) && do_await(fun, deadline)
    end
  end

  describe "mount and URL params (UI-H1, CAS-6)" do
    test "renders with an idle solver badge", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, ~s(#solver-badge[data-status="idle"]))
      assert has_element?(view, "#grid-map")
    end

    test "garbage interconnection params never crash the mount", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, "/?interconnection=%3BDROP%20TABLE")
      assert {:ok, _view, _html} = live(conn, "/?interconnection=-5")
      assert {:ok, _view, _html} = live(conn, "/?interconnection=12abc")
      assert {:ok, _view, _html} = live(conn, "/?interconnection=2")
    end
  end

  describe "unknown and malformed events (UI-M13, UI-H1)" do
    test "an unknown event is logged and ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert render_hook(view, "definitely_not_an_event", %{"foo" => "bar"})
      assert has_element?(view, "#solver-badge")
    end

    test "inject_failure with a non-numeric id is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "inject_failure", %{"type" => "transmission_line", "id" => "abc"})
      assert has_element?(view, ~s(#solver-badge[data-status="idle"]))
    end

    test "inject_failure on a non-trippable type does not wedge the UI", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "inject_failure", %{"type" => "water_facility", "id" => "3"})
      assert has_element?(view, ~s(#solver-badge[data-status="idle"]))
    end

    test "scrub_timeline with garbage is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "scrub_timeline", %{"step" => "junk"})
      refute_push_event(view, "show_cascade_step", %{step: _})
    end
  end

  describe "injection re-entrancy (UI-M22)" do
    # The window this closes is the one where the FIRST cascade is still
    # running, so the test pins the server inside the trip call rather than
    # racing a two-bus cascade that settles in milliseconds.
    test "a second click during a running cascade is ignored", %{conn: conn} do
      %{line: line} = build_island("M22-Island", -104.0)
      {:ok, view, _html} = live(conn, "/")

      hang_sim_server(assigns(view).sim_id)

      params = %{"type" => "transmission_line", "id" => Integer.to_string(line.id)}
      render_hook(view, "inject_failure", params)

      assert_receive {:trip_call, _id}, 5_000
      assert assigns(view).cascade_active
      assert status(view) == "solving"

      # Double-click. The second injection used to start its own trip task,
      # orphan the first monitor, and land {:error, :already_tripped} in the
      # middle of the running cascade -- captioning it "Already tripped" and
      # flipping cascade_active back to false, with the button offered again.
      render_hook(view, "inject_failure", params)

      refute_receive {:trip_call, _id}, 300
      assert assigns(view).cascade_active, "the running cascade must not be cancelled"
      assert status(view) == "solving"
    end

    test "a trip_rejected with no injection in flight is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:trip_rejected, :already_tripped, "transmission_line", 7})
      _ = render(view)

      assert status(view) == "idle", "a leftover rejection must not caption the current state"
    end
  end

  describe "cascade end states (CAS-3, UI-C1 contract #2, CAS-8)" do
    test "an unstable cascade is reported as Unstable and pushed to the client", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:simulation_cascade_done, %{stable: false, tripped_count: 3}})

      assert_push_event(view, "cascade_done", %{stable: false})
      assert has_element?(view, ~s(#solver-badge[data-status="unstable"]))
      assert render(view) =~ "Unstable"
      assert render(element(view, "#metric-tripped")) =~ "3"
    end

    test "a stable cascade is reported as Stable", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:simulation_cascade_done, %{stable: true, tripped_count: 1}})

      assert_push_event(view, "cascade_done", %{stable: true})
      assert has_element?(view, ~s(#solver-badge[data-status="stable"]))
    end
  end

  describe "reset symmetry (UI-M14, UI-C2)" do
    test "a server-side reset pushes reset_grid to the client", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:simulation_reset, %{}})

      assert_push_event(view, "reset_grid", %{})
      assert has_element?(view, ~s(#solver-badge[data-status="idle"]))
    end

    test "reset without a running server settles back to Idle, not a dead view", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "reset_simulation", %{})
      assert_push_event(view, "reset_grid", %{})

      # The monitored reset task catches :noproc and reports back
      assert await(fn -> status(view) == "idle" end)
    end
  end

  describe "per-step metrics and timeline (UI-M2, UI-M3, UI-H3 contract #4)" do
    defp step_payload(overrides) do
      Map.merge(
        %{
          step: 1,
          simulated_time: 0.5,
          islands: 2,
          trips: [],
          tripped_line_ids: [],
          tripped_transformer_ids: [],
          tripped_generator_ids: [],
          trip_count: 0,
          overloaded_line_ids: [],
          stressed_line_ids: [],
          rerouted_line_ids: [],
          shed_ids: [],
          balance: nil
        },
        overrides
      )
    end

    test "tripped count moves per step and counts components only", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      trips = [
        %{
          component_type: "transmission_line",
          component_id: 7,
          failure_cause: "thermal_overload",
          details: %{}
        },
        %{
          component_type: "load",
          component_id: 9,
          failure_cause: "ufls_shed",
          details: %{frequency_nadir: 59.12, shed_mw: 5.0}
        }
      ]

      send(
        view.pid,
        {:simulation_cascade_step,
         step_payload(%{trips: trips, tripped_line_ids: [7], trip_count: 2})}
      )

      # 2 events but only ONE component trip (UI-M3 + CAS-8 semantics)
      assert render(element(view, "#metric-tripped")) =~ ">\n  1\n" or
               render(element(view, "#metric-tripped")) =~ "1"

      # UI-M2: the worst shed-event nadir becomes the frequency metric
      assert render(element(view, "#metric-frequency")) =~ "59.12"
    end

    test "scrubbing pushes the array position, never the step number", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Two frames whose cascade step numbers do NOT match their positions
      send(view.pid, {:simulation_cascade_step, step_payload(%{step: 90})})
      send(view.pid, {:simulation_cascade_step, step_payload(%{step: 91})})

      assert has_element?(view, "#timeline-step-0")
      assert has_element?(view, "#timeline-step-1")

      view |> element("#timeline-step-1") |> render_click()
      assert_push_event(view, "show_cascade_step", %{step: 1})
    end
  end

  describe "error surfacing (CAS-5, UI-C3)" do
    test "a failed trip leaves cascade mode and shows an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:trip_failed, :boom, "generator", 1})

      assert_push_event(view, "cascade_done", %{stable: false})
      assert has_element?(view, ~s(#solver-badge[data-status="error"]))
      assert render(view) =~ "Simulation failed"
    end
  end

  describe "hour selection (UI-M5, ENE-1)" do
    test "an incomplete selection keeps the current hour", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "select_hour", %{"date" => "2026-08-01", "hour" => ""})
      refute_push_event(view, "reset_grid", %{})

      render_hook(view, "select_hour", %{"date" => "", "hour" => "5"})
      refute_push_event(view, "reset_grid", %{})

      # A complete selection still applies (hour changes -> grid reset)
      render_hook(view, "select_hour", %{"date" => "2026-08-01", "hour" => "5"})
      assert_push_event(view, "reset_grid", %{})
    end

    test "re-selecting the same hour is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "select_hour", %{"date" => "2026-08-01", "hour" => "5"})
      assert_push_event(view, "reset_grid", %{})

      render_hook(view, "select_hour", %{"date" => "2026-08-01", "hour" => "5"})
      refute_push_event(view, "reset_grid", %{})
    end
  end

  describe "legend completeness (UI-L7)" do
    test "voltage legend includes the 115 and 161 kV classes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html = render(view)
      assert html =~ "115 kV"
      assert html =~ "161 kV"
    end

    test "water pipeline and crypto datacenter rows exist when layers are on", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        view
        |> element("#layer-toggles-form")
        |> render_change(%{
          "water" => "true",
          "datacenters" => "true",
          "demand_density" => "false"
        })

      assert html =~ "Pipeline"
      assert html =~ "Crypto"
    end
  end

  describe "info panel names (UI-L5, UI-L6)" do
    test "extended failure states and fuel codes resolve to names", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "select_component", %{
        "type" => "generator",
        "id" => "5",
        "state" => "4",
        "fuelType" => "11"
      })

      html = render(view)
      assert html =~ "Geothermal"
      assert html =~ "Rerouted Flow"
    end
  end

  describe "scope switching in all mode (CAS-7 / UI-M6)" do
    @tag timeout: 120_000
    test "a click in a second interconnection restarts the server instead of rejecting",
         %{conn: conn} do
      %{line: line_a} = build_island("R3-West", -112.0)
      %{line: line_b} = build_island("R3-East", -80.0)

      {:ok, view, _html} = live(conn, "/")

      # First injection pins the server to interconnection A
      render_hook(view, "inject_failure", %{
        "type" => "transmission_line",
        "id" => Integer.to_string(line_a.id)
      })

      assert await(fn -> finished?(view) end),
             "first cascade never finished (status: #{inspect(status(view))})"

      # Second injection targets interconnection B. Before CAS-7 this was
      # rejected as :not_in_network forever.
      render_hook(view, "inject_failure", %{
        "type" => "transmission_line",
        "id" => Integer.to_string(line_b.id)
      })

      assert await(fn -> finished?(view) end),
             "second cascade did not run; status: #{inspect(status(view))}"

      refute status(view) == "not_in_network"
    end
  end
end
