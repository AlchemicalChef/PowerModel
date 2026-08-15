defmodule PowerModelWeb.GridLiveN1ScreeningTest do
  @moduledoc """
  UI-M11: the N-1 screening task is monitored and deadlined so the button
  can never stick at "Scanning...". Covered here:

    * the full component round trip through the monitored task
      (`:run_n1_screening` -> Task -> `{:n1_screening_done, {:ok, _}}`)
    * the `{:n1_screening_done, {:error, _}}` handler and the screen_error
      rendering in `FailureControls`
    * the ref-guarded `{:n1_screening_timeout, ref}` handler, both for the
      live ref (task hung -> error state) and a stale ref (ignored)
    * the n1-task `:DOWN` branch (task killed -> error state)
  """

  use PowerModelWeb.ConnCase, async: false

  @moduletag :db

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias PowerModel.Repo
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

  # A self-contained 2-bus island so the real screening path has a solvable,
  # non-empty snapshot to build its sim server from.
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

    :ok
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

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

  # Occupies the sim server's registry slot with a process that ACCEPTS the
  # screening task's get_state call but never replies -- pinning the task
  # inside the call so hung-task scenarios are deterministic. Reports the
  # calling task's pid back to the test.
  defp hang_sim_server(sim_id) do
    test_pid = self()

    spawn_link(fn ->
      {:ok, _} = Registry.register(PowerModel.SimulationRegistry, sim_id, nil)
      send(test_pid, :fake_server_up)

      receive do
        {:"$gen_call", {caller, _tag}, :get_state} ->
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

  describe "successful screening (UI-M11 happy path)" do
    @tag timeout: 120_000
    test "the monitored task runs to completion and re-arms the button", %{conn: conn} do
      build_island("N1-West", -112.0)

      {:ok, view, _html} = live(conn, "/")
      enter_n1_mode(view)

      html = view |> element("#run-n1-screen-btn") |> render_click()
      assert html =~ "Scanning..."

      # The task starts a real sim server, queries it, and reports back via
      # {:n1_screening_done, {:ok, _}}; the button returns to its idle label.
      assert await(fn ->
               not (render(element(view, "#run-n1-screen-btn")) =~ "Scanning...")
             end),
             "screening never completed; button stuck at Scanning..."

      refute has_element?(view, "#n1-screen-error")
      assert assigns(view).n1_task == nil
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

    test "a later successful screen clears the error and shows violations", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      enter_n1_mode(view)

      capture_log(fn ->
        send(view.pid, {:n1_screening_done, {:error, :boom}})
        assert await(fn -> has_element?(view, "#n1-screen-error") end, 5_000)
      end)

      send(view.pid, {:n1_screening_done, {:ok, 2}})

      assert await(fn -> has_element?(view, "#n1-violations") end, 5_000)
      refute has_element?(view, "#n1-screen-error")
      assert render(element(view, "#n1-violations")) =~ "2"
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

          # The task is now pinned inside the fake server's get_state call
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
