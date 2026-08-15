defmodule PowerModel.Engine.SimulationServerR3Test do
  @moduledoc """
  Round-3 remediation coverage for the engine package:

  - CAS-1: partial AC refinements are never merged/broadcast
  - CAS-4: idle sim servers reap themselves
  - CAS-8: cascade_done's tripped_count counts component trips only
  - CAS-13: reset replies immediately (rebuild runs in a continue)
  - SOL-2: solution audit compares served + dead load against snapshot demand
  - ENE-1: missing demand data falls back to baseline with a loud log
  - UI-H2 / contract #3: dc_update carries `line_loading` for lines >= 30%
  """

  use PowerModel.DataCase, async: false

  @moduletag :db

  import ExUnit.CaptureLog

  alias PowerModel.Engine.SimulationServer
  alias PowerModel.Grid.{Bus, Generator, Load, TransmissionLine}
  alias PowerModel.Solver.Solution

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  defp build_grid(load_mw \\ 60.0) do
    ic = Repo.insert!(%PowerModel.Grid.Interconnection{name: "R3TestIC"})

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

    Repo.insert!(%Load{
      p_mw: load_mw,
      q_mvar: load_mw * 0.3,
      bus_id: bus2.id,
      status: "in_service"
    })

    %{interconnection: ic, line: line, gen: gen}
  end

  defp start_sim(opts \\ []) do
    sim_id = "sim_r3_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(PowerModel.PubSub, "simulation:#{sim_id}")

    {:ok, pid} = SimulationServer.start_link(Keyword.merge([sim_id: sim_id], opts))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {sim_id, pid}
  end

  describe "CAS-4: idle reaping" do
    test "a server that receives no calls stops itself after the idle timeout" do
      build_grid()
      {_sim_id, pid} = start_sim(idle_timeout: 100)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 3_000
    end
  end

  describe "CAS-8: tripped_count semantics" do
    test "cascade_done counts component trips only, never one-per-shed-load events" do
      %{line: line} = build_grid()
      {sim_id, _pid} = start_sim()

      assert {:ok, _steps} = SimulationServer.trip_branch(sim_id, line.id)
      assert_receive {:simulation_cascade_done, payload}, 10_000

      # One manual line trip; the stranded load produces load/blackout events
      # that must NOT inflate the tripped metric.
      assert payload.tripped_count == 1
      assert payload.total_events > payload.tripped_count
    end
  end

  describe "CAS-13: async reset" do
    test "reset replies :ok, broadcasts, and the server still trips afterwards" do
      %{line: line} = build_grid()
      {sim_id, _pid} = start_sim()

      assert :ok = SimulationServer.reset(sim_id)
      assert_receive {:simulation_reset, _}, 10_000

      assert {:ok, _} = SimulationServer.trip_branch(sim_id, line.id)
      assert_receive {:simulation_cascade_done, _}, 10_000
    end
  end

  describe "CAS-1: merge_ac_solutions coverage guard" do
    defp island_solution(bus_id, load_mw) do
      Solution.new([bus_id], [1.0], [0.0], %{}, 100.0,
        total_load_mw: load_mw,
        total_gen_mw: load_mw
      )
    end

    test "islands skipped for size make the result partial" do
      dead = %{dead_load_mw: 0.0, dead_bus_count: 0}
      sols = [island_solution(1, 10.0)]

      assert {:partial, reason} =
               SimulationServer.merge_ac_solutions(sols, 1, [5000], dead, 100.0)

      assert reason =~ "5000"
    end

    test "a diverged/failed island makes the result partial" do
      dead = %{dead_load_mw: 0.0, dead_bus_count: 0}
      sols = [island_solution(1, 10.0)]

      assert {:partial, reason} = SimulationServer.merge_ac_solutions(sols, 2, [], dead, 100.0)
      assert reason =~ "1 of 2"
    end

    test "zero islands is partial, never an authoritative empty result" do
      dead = %{dead_load_mw: 0.0, dead_bus_count: 0}
      assert {:partial, _} = SimulationServer.merge_ac_solutions([], 0, [], dead, 100.0)
    end

    test "full coverage merges and carries the dead-island accounting" do
      dead = %{dead_load_mw: 12.5, dead_bus_count: 3}
      sols = [island_solution(1, 10.0), island_solution(2, 20.0)]

      assert {:ok, merged} = SimulationServer.merge_ac_solutions(sols, 2, [], dead, 100.0)
      assert merged.total_load_mw == 30.0
      assert merged.dead_load_mw == 12.5
      assert merged.dead_bus_count == 3
      assert merged.converged
    end
  end

  describe "SOL-2: snapshot-anchored audit" do
    test "load that silently vanished from the solve is flagged" do
      # Internal identity holds (0 - 0 - 0 = 0) but 100 MW of snapshot load
      # is unaccounted -- the tautological audit passed this before.
      empty = Solution.new([], [], [], %{}, 100.0)

      log =
        capture_log(fn ->
          SimulationServer.audit_solution(empty, "audit_test", 100.0)
        end)

      assert log =~ "energy balance violated"
      assert log =~ "unaccounted"
    end

    test "served + dead-island load accounting passes" do
      solution =
        Solution.new([1], [1.0], [0.0], %{}, 100.0,
          total_load_mw: 60.0,
          total_gen_mw: 60.0,
          dead_load_mw: 40.0,
          dead_bus_count: 2
        )

      log =
        capture_log(fn ->
          SimulationServer.audit_solution(solution, "audit_test", 100.0)
        end)

      refute log =~ "energy balance violated"
    end
  end

  describe "ENE-1: default demand hour" do
    test "no hour option and no demand data logs the baseline fallback loudly" do
      build_grid()

      log =
        capture_log(fn ->
          {_sim_id, _pid} = start_sim()
        end)

      assert log =~ "BASELINE"
    end
  end

  describe "UI-H2 / contract #3: line_loading payload" do
    test "dc_update carries per-line loading for lines >= 30% loaded" do
      # 90 MW over a 200 MVA line = 45% loading
      %{line: line} = build_grid(90.0)
      {_sim_id, _pid} = start_sim()

      assert_receive {:simulation_dc_update, payload}, 10_000
      assert is_map(payload.line_loading)
      assert_in_delta payload.line_loading[line.id], 45.0, 0.5
    end

    test "lines below 30% are absent (client defaults them to the lowest band)" do
      # 20 MW over a 200 MVA line = 10% loading
      %{line: line} = build_grid(20.0)
      {_sim_id, _pid} = start_sim()

      assert_receive {:simulation_dc_update, payload}, 10_000
      refute Map.has_key?(payload.line_loading, line.id)
    end
  end
end
