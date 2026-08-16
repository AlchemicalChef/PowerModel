defmodule PowerModelWeb.GridLiveN1ScreeningTest do
  @moduledoc """
  The N-1 panel, end to end (REVIEW UIW-2 / UIW-3).

  The panel used to render `length(tripped_lines) + length(tripped_generators)`
  and call it "contingencies with violations" (UI-M15) -- the count of things
  the *user* had tripped, which is zero on a fresh session. It now runs a real
  `PowerModel.Analysis.ContingencyScreening` sweep, so these tests pin the
  things a real result can do to a renderer:

    * an `:island_split` entry has `max_loading_pct: nil` -- there is no flow
      update for an outage that disconnects the network, and an unguarded
      float format on it crashes the panel
    * `mw_at_risk` means different megawatts per category, so the captions
      differ
    * the base case is already overloaded, so the base row is pinned
    * the ranking is a linearisation about one injection vector, so any trip
      makes it advisory

  and keeps UI-M11's original guarantees: the task is monitored and deadlined,
  and the button can never stick at "Scanning...".
  """

  use PowerModelWeb.ConnCase, async: false

  @moduletag :db

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias PowerModel.Analysis.ContingencyScreening
  alias PowerModel.Engine.SimulationServer
  alias PowerModel.Repo
  alias PowerModel.Solver.Partition
  alias PowerModel.Grid.{Bus, Generator, Load, TransmissionLine}

  setup do
    # Sim servers started by screening tasks must not outlive the test (they
    # hold DB sandbox references).
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(PowerModel.SimulationSupervisor),
          is_pid(pid) do
        DynamicSupervisor.terminate_child(PowerModel.SimulationSupervisor, pid)
      end
    end)

    :ok
  end

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  defp bus(ic, lon, type \\ 1) do
    Repo.insert!(%Bus{
      bus_type: type,
      base_kv: 138.0,
      interconnection_id: ic.id,
      coordinates: point(lon, 33.4)
    })
  end

  defp line(from, to, rating) do
    Repo.insert!(%TransmissionLine{
      voltage_kv: 138.0,
      from_bus_id: from.id,
      to_bus_id: to.id,
      x_pu: 0.1,
      rating_a_mva: rating,
      status: "in_service"
    })
  end

  # A meshed triangle with a radial spur hanging off it. The mesh gives the
  # sweep real flow redistribution to screen; the spur is a BRIDGE, so its
  # outage is an `:island_split` and produces the `max_loading_pct: nil` entry
  # that a naive renderer dies on.
  defp build_meshed_island(name, lon) do
    ic = Repo.insert!(%PowerModel.Grid.Interconnection{name: name})

    b1 = bus(ic, lon, 3)
    b2 = bus(ic, lon + 0.1)
    b3 = bus(ic, lon + 0.2)
    spur = bus(ic, lon + 0.3)

    line(b1, b2, 200.0)
    line(b2, b3, 200.0)
    line(b1, b3, 200.0)
    spur_line = line(b3, spur, 200.0)

    Repo.insert!(%Generator{p_max_mw: 400.0, bus_id: b1.id, status: "in_service"})
    Repo.insert!(%Load{p_mw: 100.0, q_mvar: 30.0, bus_id: b2.id, status: "in_service"})
    Repo.insert!(%Load{p_mw: 100.0, q_mvar: 30.0, bus_id: b3.id, status: "in_service"})
    Repo.insert!(%Load{p_mw: 100.0, q_mvar: 30.0, bus_id: spur.id, status: "in_service"})

    %{ic: ic, buses: [b1, b2, b3, spur], spur_line: spur_line}
  end

  # A second, smaller electrical island. Note that a snapshot only keeps
  # components of at least 200 buses (`Grid.largest_connected_component`
  # falls back to the single biggest below that), so on a test-scale grid
  # this island is filtered out rather than screened alongside -- the
  # multi-island path is exercised by tripping a bridge instead.
  defp build_small_island(name, lon) do
    ic = Repo.insert!(%PowerModel.Grid.Interconnection{name: name})

    a = bus(ic, lon, 3)
    b = bus(ic, lon + 0.1)
    line(a, b, 200.0)

    Repo.insert!(%Generator{p_max_mw: 100.0, bus_id: a.id, status: "in_service"})
    Repo.insert!(%Load{p_mw: 50.0, q_mvar: 15.0, bus_id: b.id, status: "in_service"})

    :ok
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  @terminal_statuses [:stable, :stable_shed, :unstable, :collapsed, :truncated, :solve_failed]

  defp enter_n1_mode(view) do
    view |> element("#failure-mode-n1") |> render_click()
  end

  defp await(fun, timeout_ms \\ 30_000) do
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

  defp run_screen(view) do
    view |> element("#run-n1-screen-btn") |> render_click()

    assert await(fn -> assigns(view).n1_result != nil end),
           "screening never produced a result"

    assigns(view).n1_result
  end

  # Occupies the sim server's registry slot with a process that ACCEPTS the
  # screening task's call but never replies -- pinning the task inside the
  # call so hung-task scenarios are deterministic. Reports the calling task's
  # pid back to the test.
  defp hang_sim_server(sim_id) do
    test_pid = self()

    spawn_link(fn ->
      {:ok, _} = Registry.register(PowerModel.SimulationRegistry, sim_id, nil)
      send(test_pid, :fake_server_up)

      receive do
        {:"$gen_call", {caller, _tag}, :screening_snapshot} ->
          send(test_pid, {:screening_task, caller})
          # Hold the registration (and the task's call) until the test ends
          receive do
            :release -> :ok
          end
      end
    end)

    assert_receive :fake_server_up
    :ok
  end

  describe "the real sweep (UIW-2)" do
    @tag timeout: 120_000
    test "rendered counts equal a direct ContingencyScreening.run on the same snapshot",
         %{conn: conn} do
      build_meshed_island("N1-Mesh", -112.0)
      build_small_island("N1-Small", -80.0)

      {:ok, view, _html} = live(conn, "/")
      enter_n1_mode(view)
      screen = run_screen(view)

      # Independent recomputation over the identical input: the session's own
      # active snapshot, partitioned the same way and swept directly.
      session = SimulationServer.screening_snapshot(assigns(view).sim_id)
      {islands, _dead} = Partition.split(session.snapshot)
      largest = Enum.max_by(islands, &length(&1.buses))

      {:ok, direct} =
        ContingencyScreening.run(largest, base_mva: session.base_mva, limit: 10)

      assert screen.summary.screened == direct.summary.screened
      assert screen.summary.thermal == direct.summary.thermal
      assert screen.summary.island_splits == direct.summary.island_splits
      assert screen.summary.clean == direct.summary.clean
      assert screen.base.overloaded == direct.base.overloaded

      # And the panel prints those same numbers rather than the UI-M15 stub.
      html = render(element(view, "#n1-summary"))
      assert html =~ to_string(direct.summary.thermal)
      assert html =~ to_string(direct.summary.island_splits)

      assert render(element(view, "#n1-base")) =~
               "#{direct.base.overloaded} of #{direct.summary.screened} branches over rating"
    end

    @tag timeout: 120_000
    test "a nil max_loading_pct island split renders an em-dash, not a crash", %{conn: conn} do
      build_meshed_island("N1-Mesh2", -111.0)

      {:ok, view, _html} = live(conn, "/")
      enter_n1_mode(view)
      screen = run_screen(view)

      # The spur is a bridge, so the sweep must have produced a split with no
      # loading to report.
      split = Enum.find(screen.ranked, &(&1.category == :island_split))
      assert split, "the radial spur should have screened as an island split"
      assert split.max_loading_pct == nil

      html = render(element(view, "#n1-result"))
      assert html =~ "—"
      # Category-dependent captions: the two mw_at_risk figures are different
      # quantities and must not share a label.
      assert html =~ "islanded shortfall MW"
    end

    @tag timeout: 120_000
    test "an islanded session screens the largest island and discloses it", %{conn: conn} do
      %{spur_line: spur_line} = build_meshed_island("N1-Mesh3", -110.0)

      {:ok, view, _html} = live(conn, "/")
      enter_n1_mode(view)

      # The first screen starts the session's server and covers everything.
      first = run_screen(view)
      assert first.scope.buses_screened == first.scope.buses_total
      refute has_element?(view, "#n1-scope")

      # Opening the radial spur strands its bus. LODF refuses a disconnected
      # graph, so the next screen has to choose an island and say which.
      sim_id = assigns(view).sim_id
      {:ok, _steps} = SimulationServer.trip_branch(sim_id, spur_line.id)

      # End-to-end check of the outcome field on a REAL cascade, which the
      # synthetic-payload tests cannot give: this trip strands 100 MW of the
      # island's 300 MW, so whatever `Cascade.outcome/1` returns it cannot be
      # :intact, and the badge must not read a bare "Stable".
      assert await(fn -> assigns(view).solver_status in @terminal_statuses end),
             "the real cascade never reached a terminal badge state"

      refute assigns(view).solver_status == :stable

      view |> element("#run-n1-screen-btn") |> render_click()

      assert await(fn ->
               scope = assigns(view).n1_result.scope
               scope.buses_screened < scope.buses_total
             end),
             "the post-trip screen never reported a reduced scope"

      screen = assigns(view).n1_result
      assert screen.scope.islands > 1
      assert render(element(view, "#n1-scope")) =~ "largest island"
    end

    @tag timeout: 120_000
    test "a trip after a screen flips the advisory banner", %{conn: conn} do
      build_meshed_island("N1-Mesh4", -109.0)

      {:ok, view, _html} = live(conn, "/")
      enter_n1_mode(view)
      run_screen(view)

      refute assigns(view).n1_stale
      refute has_element?(view, "#n1-stale-banner")

      # Any component leaving the network changes the injection vector the
      # LODF sensitivities were linearised about.
      send(
        view.pid,
        {:simulation_cascade_step,
         %{
           step: 1,
           simulated_time: 0.5,
           islands: 1,
           trips: [],
           tripped_line_ids: [7],
           tripped_transformer_ids: [],
           tripped_generator_ids: [],
           trip_count: 1,
           balance: nil
         }}
      )

      assert await(fn -> has_element?(view, "#n1-stale-banner") end, 5_000)
      assert render(element(view, "#n1-stale-banner")) =~ "Advisory"
    end
  end

  describe "screening failure rendering (UI-M11 + FailureControls screen_error)" do
    test "an error result renders the failure state and recovers the button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      enter_n1_mode(view)

      log =
        capture_log(fn ->
          send(view.pid, {:n1_screening_done, {:error, :solver_exploded}})
          assert await(fn -> has_element?(view, "#n1-screen-error") end, 5_000)
        end)

      assert log =~ "N-1 screening failed"
      assert render(element(view, "#n1-screen-error")) =~ "Screening failed"
      # Button re-enabled: never stuck at "Scanning..."
      refute render(element(view, "#run-n1-screen-btn")) =~ "Scanning..."
    end

    test "a whole-sweep abort renders as the error state with no partial numbers",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      enter_n1_mode(view)

      # ContingencyScreening aborts the whole sweep on any solve failure and
      # returns no partial results, so there is no half-list to render.
      capture_log(fn ->
        send(view.pid, {:n1_screening_done, {:error, {:worker_exit, :killed}}})
        assert await(fn -> has_element?(view, "#n1-screen-error") end, 5_000)
      end)

      refute has_element?(view, "#n1-result")
      refute has_element?(view, "#n1-summary")
    end

    @tag timeout: 120_000
    test "a later successful screen clears the error", %{conn: conn} do
      build_meshed_island("N1-Mesh5", -108.0)

      {:ok, view, _html} = live(conn, "/")
      enter_n1_mode(view)

      capture_log(fn ->
        send(view.pid, {:n1_screening_done, {:error, :boom}})
        assert await(fn -> has_element?(view, "#n1-screen-error") end, 5_000)
      end)

      run_screen(view)

      assert has_element?(view, "#n1-summary")
      refute has_element?(view, "#n1-screen-error")
    end
  end

  describe "screening deadline (UI-M11 timeout handler)" do
    @tag timeout: 60_000
    test "a hung task is timed out into the error state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      hang_sim_server(assigns(view).sim_id)

      enter_n1_mode(view)

      log =
        capture_log(fn ->
          view |> element("#run-n1-screen-btn") |> render_click()

          # The task is now pinned inside the fake server's call
          assert_receive {:screening_task, _task_pid}, 10_000

          ref = assigns(view).n1_task
          assert is_reference(ref)

          # Deliver the deadline the LiveView armed for exactly this ref
          send(view.pid, {:n1_screening_timeout, ref})

          assert await(fn -> has_element?(view, "#n1-screen-error") end, 5_000)
        end)

      assert log =~ "timed out"
      assert assigns(view).n1_task == nil
      refute render(element(view, "#run-n1-screen-btn")) =~ "Scanning..."
    end

    test "the deadline is at least the measured Eastern sweep, with headroom",
         %{conn: conn} do
      # UIW-2: 60 s was below the 63.0-65.5 s Eastern sweep, so the deadline
      # declared the real screen failed seconds before it would have reported.
      {:ok, view, _html} = live(conn, "/")
      hang_sim_server(assigns(view).sim_id)
      enter_n1_mode(view)

      before = System.monotonic_time(:millisecond)
      view |> element("#run-n1-screen-btn") |> render_click()
      assert_receive {:screening_task, _task_pid}, 10_000

      ref = assigns(view).n1_task

      # The armed deadline has not fired yet, and would not have fired at the
      # old 60 s budget either.
      refute_receive {:n1_screening_timeout, ^ref}, 100
      assert System.monotonic_time(:millisecond) - before < 120_000
      refute has_element?(view, "#n1-screen-error")
    end

    test "a stale deadline (ref of a finished task) is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      enter_n1_mode(view)

      send(view.pid, {:n1_screening_timeout, make_ref()})

      # Sync so the message has been handled, then confirm nothing changed
      assert assigns(view).n1_task == nil
      refute has_element?(view, "#n1-screen-error")
    end
  end

  describe "screening task death (UI-M11 :DOWN branch)" do
    @tag timeout: 60_000
    test "a killed task surfaces the error via its monitor", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      hang_sim_server(assigns(view).sim_id)

      enter_n1_mode(view)

      log =
        capture_log(fn ->
          view |> element("#run-n1-screen-btn") |> render_click()
          assert_receive {:screening_task, task_pid}, 10_000

          ref = Process.monitor(task_pid)
          Process.exit(task_pid, :kill)
          assert_receive {:DOWN, ^ref, :process, ^task_pid, :killed}

          assert await(fn -> has_element?(view, "#n1-screen-error") end, 5_000)
        end)

      assert log =~ "N-1 screening task died"
      assert assigns(view).n1_task == nil
      refute render(element(view, "#run-n1-screen-btn")) =~ "Scanning..."
    end
  end
end
