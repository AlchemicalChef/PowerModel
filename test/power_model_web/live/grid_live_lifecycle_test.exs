defmodule PowerModelWeb.GridLiveLifecycleTest do
  @moduledoc """
  Session lifecycle coverage:

    * CAS-4 (LiveView half): `terminate/2` stops the session's simulation
      server so a closed browser tab does not leave a permanent GenServer
      holding a full grid snapshot.
    * UI-C3: a failed `DynamicSupervisor.start_child` surfaces as an error
      state instead of an eternal "Solving..." spinner.
  """

  use PowerModelWeb.ConnCase, async: false

  @moduletag :db

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias PowerModel.Engine.SimulationServer
  alias PowerModel.Repo
  alias PowerModel.Grid.{Bus, Generator, Load, TransmissionLine}

  setup do
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(PowerModel.SimulationSupervisor),
          is_pid(pid) do
        DynamicSupervisor.terminate_child(PowerModel.SimulationSupervisor, pid)
      end
    end)

    :ok
  end

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

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

    %{interconnection: ic}
  end

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

  describe "LiveView terminate/2 (CAS-4)" do
    @tag timeout: 120_000
    test "closing the session stops its simulation server", %{conn: conn} do
      %{interconnection: ic} = build_island("CAS4-West", -110.0)

      # The test process is linked to the LiveView under test; trap exits so
      # deliberately stopping the view does not take the test down with it.
      Process.flag(:trap_exit, true)

      {:ok, view, _html} = live(conn, "/")
      sim_id = :sys.get_state(view.pid).socket.assigns.sim_id

      {:ok, server_pid} =
        DynamicSupervisor.start_child(
          PowerModel.SimulationSupervisor,
          {SimulationServer, [sim_id: sim_id, interconnection_id: ic.id, hour: nil]}
        )

      assert [{^server_pid, _}] = Registry.lookup(PowerModel.SimulationRegistry, sim_id)

      server_ref = Process.monitor(server_pid)

      # A graceful stop runs the channel's terminate, which runs the
      # LiveView's terminate/2 (brutal kills that skip terminate/2 are the
      # server's own idle-timeout backstop's job).
      GenServer.stop(view.pid, :shutdown)

      assert_receive {:DOWN, ^server_ref, :process, ^server_pid, _reason}, 10_000
      assert await(fn -> Registry.lookup(PowerModel.SimulationRegistry, sim_id) == [] end)
    end
  end

  describe "server start failure (UI-C3)" do
    test "a failed server start shows an error, not an eternal spinner", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/?interconnection=2")

      # Revoke DB access for processes spawned from here on (the suite's
      # baseline sandbox mode is :manual; each test's owner re-shares it, and
      # the NEXT test's setup restores that). The sim server's init then
      # crashes on its snapshot query, so DynamicSupervisor.start_child
      # returns {:error, reason} -- the exact branch under test. The view
      # itself needs no DB access on this code path (scope "2" parses
      # without the interconnection-resolving query).
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

      log =
        capture_log(fn ->
          render_hook(view, "inject_failure", %{"type" => "transmission_line", "id" => "1"})

          # Synchronous: start_child failed inside handle_event
          assert has_element?(view, ~s(#solver-badge[data-status="error"]))
        end)

      assert log =~ "simulation server start failed"
      assert_push_event(view, "cascade_done", %{stable: false})
      assert render(view) =~ "Simulation failed"
      refute :sys.get_state(view.pid).socket.assigns.cascade_active
    end
  end
end
