defmodule PowerModel.Engine.SimulationServerTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Engine.SimulationServer
  alias PowerModel.Grid.{Bus, Generator, Load, TransmissionLine}

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  setup do
    ic = Repo.insert!(%PowerModel.Grid.Interconnection{name: "TestIC"})

    bus1 =
      Repo.insert!(%Bus{
        bus_type: 3,
        base_kv: 138.0,
        interconnection_id: ic.id,
        coordinates: point(-112.0, 33.4)
      })

    bus2 =
      Repo.insert!(%Bus{
        bus_type: 1,
        base_kv: 138.0,
        interconnection_id: ic.id,
        coordinates: point(-111.9, 33.5)
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

    gen = Repo.insert!(%Generator{p_max_mw: 100.0, bus_id: bus1.id, status: "in_service"})
    Repo.insert!(%Load{p_mw: 60.0, q_mvar: 18.0, bus_id: bus2.id, status: "in_service"})

    sim_id = "sim_test_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(PowerModel.PubSub, "simulation:#{sim_id}")

    {:ok, pid} = SimulationServer.start_link(sim_id: sim_id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    %{sim_id: sim_id, tline: line, gen: gen}
  end

  test "manual line trip reaches subscribers as a step-0 tripped id", %{
    sim_id: sim_id,
    tline: line
  } do
    assert {:ok, _steps} = SimulationServer.trip_branch(sim_id, line.id)

    # The injected failure itself is broadcast immediately (step 0)
    assert_receive {:simulation_cascade_step, %{step: 0} = payload}, 5_000
    assert line.id in payload.tripped_line_ids
    assert [%{failure_cause: "manual_trip"}] = payload.trips

    # The cascade and final repaint follow
    assert_receive {:simulation_cascade_step, %{step: 1}}, 5_000
    assert_receive {:simulation_cascade_done, done}, 5_000
    assert done.balance.original_load_mw > 0.0
  end

  test "manual generator trip is broadcast as a step-0 tripped id", %{
    sim_id: sim_id,
    gen: gen
  } do
    assert {:ok, _steps} = SimulationServer.trip_generator(sim_id, gen.id)

    assert_receive {:simulation_cascade_step, %{step: 0} = payload}, 5_000
    assert gen.id in payload.tripped_generator_ids
  end

  test "tripping an unknown component is rejected without broadcasts", %{sim_id: sim_id} do
    assert {:error, :not_in_network} = SimulationServer.trip_branch(sim_id, 999_999_999)
    refute_receive {:simulation_cascade_step, _}, 200
  end

  test "stale AC results from a pre-reset topology are discarded", %{sim_id: sim_id} do
    [{pid, _}] = Registry.lookup(PowerModel.SimulationRegistry, sim_id)
    solution = PowerModel.Solver.Solution.new([], [], [], %{}, 100.0)

    # Epoch starts at 0; reset bumps it to 1
    :ok = SimulationServer.reset(sim_id)
    assert_receive {:simulation_reset, _}, 1_000

    # An AC task spawned before the reset reports with the old epoch -> dropped
    send(pid, {:ac_result, 0, solution})
    refute_receive {:simulation_ac_update, _}, 300

    # A result for the current topology still lands
    send(pid, {:ac_result, 1, solution})
    assert_receive {:simulation_ac_update, _}, 1_000
  end

  test "re-tripping the same component is rejected as already_tripped", %{
    sim_id: sim_id,
    tline: line
  } do
    assert {:ok, _} = SimulationServer.trip_branch(sim_id, line.id)

    # Drain the first trip's broadcasts
    receive_loop = fn loop ->
      receive do
        {:simulation_cascade_step, _} -> loop.(loop)
        {:simulation_cascade_done, _} -> loop.(loop)
        {:simulation_dc_update, _} -> loop.(loop)
      after
        300 -> :ok
      end
    end

    receive_loop.(receive_loop)

    assert {:error, :already_tripped} = SimulationServer.trip_branch(sim_id, line.id)
    refute_receive {:simulation_cascade_step, _}, 200
  end
end
