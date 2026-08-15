defmodule PowerModel.Grid.BtmSolarIdentityTest do
  @moduledoc """
  THE REPRESENTATION RULE regression (ROADMAP Phase 2.5 item 30).

  EIA-930 demand is metered NET of behind-the-meter output, so modeling rooftop
  PV as a bus-level gross-up plus a generation injection at the same bus nets to
  zero. Every steady-state result must therefore be IDENTICAL whether the
  `:btm_solar` layer is populated or empty — not close, identical.

  This is the test that fails the moment a solver, a dispatch pass, or load
  scaling starts reading `:btm_solar`, which would double-count rooftop against
  demand that already excludes it. The layer is inert until something perturbs
  `output_mw` (IEEE 1547 tripping, cloud scenarios); that perturbation is what
  ROADMAP item 31 builds, and it must be the ONLY thing that moves a solve.
  """

  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Demand.{BADemandHour, BAFuelHour}
  alias PowerModel.Grid

  alias PowerModel.Grid.{
    BalancingAuthority,
    BtmSolar,
    Bus,
    Generator,
    Interconnection,
    Load,
    TransmissionLine
  }

  alias PowerModel.Solver.DCPowerFlow

  @hour ~U[2024-07-15 19:00:00Z]

  setup do
    ba = Repo.insert!(%BalancingAuthority{code: "CISO", name: "California ISO"})
    ic = Repo.insert!(%Interconnection{name: "TestIC"})

    buses =
      for {type, lon, lat} <- [{3, -117.1, 32.7}, {1, -117.0, 32.8}, {1, -116.9, 32.9}] do
        Repo.insert!(%Bus{
          bus_type: type,
          base_kv: 138.0,
          balancing_authority_id: ba.id,
          interconnection_id: ic.id,
          coordinates: %Geo.Point{coordinates: {lon, lat}, srid: 4326}
        })
      end

    [slack, mid, tail] = buses

    for {a, b} <- [{slack, mid}, {mid, tail}] do
      Repo.insert!(%TransmissionLine{
        voltage_kv: 138.0,
        from_bus_id: a.id,
        to_bus_id: b.id,
        x_pu: 0.1,
        rating_a_mva: 200.0,
        geometry: %Geo.LineString{coordinates: [{-117.1, 32.7}, {-117.0, 32.8}], srid: 4326},
        status: "in_service"
      })
    end

    Repo.insert!(%Generator{p_max_mw: 500.0, bus_id: slack.id, status: "in_service"})

    # The BA's utility-solar fleet, which sets the capacity-factor denominator.
    Repo.insert!(%Generator{
      p_max_mw: 1000.0,
      summer_capacity_mw: 1000.0,
      fuel_type: "SUN",
      bus_id: slack.id,
      status: "in_service"
    })

    Repo.insert!(%Load{p_mw: 80.0, q_mvar: 24.0, bus_id: mid.id, status: "in_service"})
    Repo.insert!(%Load{p_mw: 40.0, q_mvar: 12.0, bus_id: tail.id, status: "in_service"})

    Repo.insert!(%BADemandHour{
      balancing_authority_id: ba.id,
      timestamp_utc: @hour,
      demand_mw: 240.0
    })

    # 600 of 1000 MW -> capacity factor 0.6, so the rooftop below is not idle.
    Repo.insert!(%BAFuelHour{
      ba_code: "CISO",
      timestamp_utc: @hour,
      fuel: "solar",
      net_generation_mw: 600.0
    })

    %{mid: mid, tail: tail}
  end

  defp add_btm_solar(buses) do
    rows =
      Enum.flat_map(buses, fn bus ->
        for {sector, mw} <- [{"residential", 30.0}, {"commercial", 12.0}] do
          %{
            bus_id: bus.id,
            sector: sector,
            capacity_mw: mw,
            state: "CA",
            utility_id: "12345",
            inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
            updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
          }
        end
      end)

    Repo.insert_all(BtmSolar, rows)
  end

  # Everything a steady-state consumer can observe, minus the layer itself.
  defp steady_state(snapshot) do
    solution = DCPowerFlow.solve(snapshot)

    %{
      buses:
        Enum.map(snapshot.buses, &Map.take(&1, [:id, :bus_type, :base_kv, :gs_mw, :bs_mvar])),
      loads: Enum.map(snapshot.loads, &Map.take(&1, [:bus_id, :p_mw, :q_mvar, :load_type])),
      generators: Enum.map(snapshot.generators, &Map.take(&1, [:bus_id, :p_max_mw, :fuel_type])),
      solution:
        Map.take(solution, [
          :bus_ids,
          :va_rad,
          :vm_pu,
          :line_flows,
          :total_gen_mw,
          :total_load_mw,
          :slack_injection_mw,
          :mismatch_mw,
          :converged
        ])
    }
  end

  describe "the layer is inert for steady state" do
    test "the DC solution is identical with and without btm_solar, at an hour", %{
      mid: mid,
      tail: tail
    } do
      without = steady_state(Grid.get_full_grid_snapshot(hour: @hour))

      add_btm_solar([mid, tail])

      with_layer = steady_state(Grid.get_full_grid_snapshot(hour: @hour))

      assert with_layer == without
    end

    test "identical on the baseline (no hour) snapshot too", %{mid: mid, tail: tail} do
      without = steady_state(Grid.get_full_grid_snapshot())

      add_btm_solar([mid, tail])

      assert steady_state(Grid.get_full_grid_snapshot()) == without
    end

    test "identical for the per-interconnection snapshot", %{mid: mid, tail: tail} do
      ic = Repo.one!(from i in Interconnection, where: i.name == "TestIC")

      without = steady_state(Grid.get_grid_snapshot(ic.id, hour: @hour))

      add_btm_solar([mid, tail])

      assert steady_state(Grid.get_grid_snapshot(ic.id, hour: @hour)) == without
    end

    test "identical for the regional snapshot", %{mid: mid, tail: tail} do
      bounds = {-118.0, 32.0, -116.0, 33.5}

      without = steady_state(Grid.get_regional_grid_snapshot(bounds, hour: @hour))

      add_btm_solar([mid, tail])

      assert steady_state(Grid.get_regional_grid_snapshot(bounds, hour: @hour)) == without
    end

    test "hourly load scaling ignores the layer — demand is already net of it", %{
      mid: mid,
      tail: tail
    } do
      scaled_without =
        Grid.get_full_grid_snapshot(hour: @hour).loads
        |> Enum.map(&{&1.bus_id, &1.p_mw, &1.q_mvar})
        |> Enum.sort()

      add_btm_solar([mid, tail])

      scaled_with =
        Grid.get_full_grid_snapshot(hour: @hour).loads
        |> Enum.map(&{&1.bus_id, &1.p_mw, &1.q_mvar})
        |> Enum.sort()

      assert scaled_with == scaled_without

      # ...and the scaling really did fire, so the comparison is not of two
      # untouched baselines.
      assert Enum.sum(Enum.map(scaled_with, &elem(&1, 1))) == 240.0
    end
  end

  describe "the layer is present and non-trivial" do
    # Guards the identity tests above from passing vacuously: if the snapshot
    # carried nothing, or everything carried 0 MW of output, "identical" would
    # be meaningless.
    test "the snapshot carries the entries with real output behind them", %{
      mid: mid,
      tail: tail
    } do
      assert Grid.get_full_grid_snapshot(hour: @hour).btm_solar == []

      add_btm_solar([mid, tail])

      entries = Grid.get_full_grid_snapshot(hour: @hour).btm_solar

      assert length(entries) == 4
      assert Enum.sum(Enum.map(entries, & &1.capacity_mw)) == 84.0

      # Capacity factor 0.6 across 84 MW of rooftop.
      assert_in_delta Enum.sum(Enum.map(entries, & &1.output_mw)), 50.4, 1.0e-9

      assert Enum.all?(entries, &(&1.legacy_fraction == 0.30))
      assert Enum.all?(entries, &(&1.bus_id in [mid.id, tail.id]))

      assert entries |> Enum.map(& &1.sector) |> Enum.uniq() |> Enum.sort() ==
               ["commercial", "residential"]
    end

    test "output is zero on a snapshot with no hour, and capacity still travels", %{
      mid: mid,
      tail: tail
    } do
      add_btm_solar([mid, tail])

      entries = Grid.get_full_grid_snapshot().btm_solar

      assert Enum.sum(Enum.map(entries, & &1.capacity_mw)) == 84.0
      assert Enum.all?(entries, &(&1.output_mw == 0.0))
    end
  end
end
