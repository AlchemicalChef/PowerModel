defmodule PowerModel.Grid.BtmSolarTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Demand.BAFuelHour
  alias PowerModel.Grid.{BalancingAuthority, BtmSolar, Bus, Generator}

  @hour ~U[2024-07-15 19:00:00Z]

  setup do
    ba = Repo.insert!(%BalancingAuthority{code: "CISO", name: "California ISO"})
    bus = Repo.insert!(%Bus{bus_type: 1, base_kv: 138.0, balancing_authority_id: ba.id})

    %{ba: ba, bus: bus}
  end

  defp solar_fleet(bus, summer_mw) do
    Repo.insert!(%Generator{
      p_max_mw: summer_mw * 2,
      summer_capacity_mw: summer_mw,
      winter_capacity_mw: summer_mw,
      fuel_type: "SUN",
      status: "in_service",
      bus_id: bus.id
    })
  end

  defp measured_solar(ba_code, mw, hour \\ @hour) do
    Repo.insert!(%BAFuelHour{
      ba_code: ba_code,
      timestamp_utc: hour,
      fuel: "solar",
      net_generation_mw: mw
    })
  end

  defp entries(bus, capacity_mw, sector \\ "residential") do
    [%{bus_id: bus.id, sector: sector, capacity_mw: capacity_mw}]
  end

  describe "output_at/3 capacity factor proxy" do
    test "shapes rooftop output by the BA's own utility-solar capacity factor", %{
      bus: bus
    } do
      solar_fleet(bus, 1000.0)
      measured_solar("CISO", 600.0)

      assert [entry] = BtmSolar.output_at(entries(bus, 50.0), @hour)

      # 600 / 1000 = 0.6 -> 50 MW of rooftop delivers 30 MW.
      assert_in_delta entry.output_mw, 30.0, 1.0e-9
      assert entry.capacity_mw == 50.0
      assert entry.sector == "residential"
      assert entry.bus_id == bus.id
    end

    test "reads winter capability outside April-September", %{bus: bus} do
      Repo.insert!(%Generator{
        p_max_mw: 5000.0,
        summer_capacity_mw: 1000.0,
        winter_capacity_mw: 500.0,
        fuel_type: "SUN",
        status: "in_service",
        bus_id: bus.id
      })

      winter_hour = ~U[2024-12-15 19:00:00Z]
      measured_solar("CISO", 250.0, winter_hour)

      assert [entry] = BtmSolar.output_at(entries(bus, 100.0), winter_hour)

      # 250 / 500 = 0.5, not 250 / 1000.
      assert_in_delta entry.output_mw, 50.0, 1.0e-9
    end

    test "falls back to nameplate when EIA reported no seasonal capability", %{bus: bus} do
      Repo.insert!(%Generator{
        p_max_mw: 400.0,
        fuel_type: "SUN",
        status: "in_service",
        bus_id: bus.id
      })

      measured_solar("CISO", 100.0)

      assert [entry] = BtmSolar.output_at(entries(bus, 20.0), @hour)
      assert_in_delta entry.output_mw, 5.0, 1.0e-9
    end

    test "only solar plant counts toward the denominator", %{bus: bus} do
      solar_fleet(bus, 1000.0)

      Repo.insert!(%Generator{
        p_max_mw: 9000.0,
        summer_capacity_mw: 9000.0,
        fuel_type: "NG",
        status: "in_service",
        bus_id: bus.id
      })

      measured_solar("CISO", 500.0)

      assert [entry] = BtmSolar.output_at(entries(bus, 10.0), @hour)
      assert_in_delta entry.output_mw, 5.0, 1.0e-9
    end

    test "onsite (non-utility-scale) solar is out of the denominator", %{bus: bus} do
      # EIA-930's solar column is UTILITY-SCALE generation, and Dispatch
      # allocates it to utility_scale units only (ROADMAP item 29). Counting
      # the onsite fleet in the denominator here would divide utility-scale
      # generation by a larger capability and bias every rooftop CF low.
      solar_fleet(bus, 1000.0)

      Repo.insert!(%Generator{
        p_max_mw: 1000.0,
        summer_capacity_mw: 1000.0,
        fuel_type: "SUN",
        status: "in_service",
        utility_scale: false,
        bus_id: bus.id
      })

      measured_solar("CISO", 500.0)

      assert [entry] = BtmSolar.output_at(entries(bus, 10.0), @hour)
      assert_in_delta entry.output_mw, 5.0, 1.0e-9
    end

    test "a NULL utility_scale unit still counts — it reads as utility-scale", %{bus: bus} do
      # MATPOWER imports and import pseudo-generators never went through the
      # EIA-860 ingest, so they carry NULL rather than a decision.
      Repo.insert!(%Generator{
        p_max_mw: 1000.0,
        summer_capacity_mw: 1000.0,
        fuel_type: "SUN",
        status: "in_service",
        utility_scale: nil,
        bus_id: bus.id
      })

      measured_solar("CISO", 600.0)

      assert [entry] = BtmSolar.output_at(entries(bus, 50.0), @hour)
      assert_in_delta entry.output_mw, 30.0, 1.0e-9
    end

    test "retired solar plant is out of the denominator", %{bus: bus} do
      solar_fleet(bus, 1000.0)

      Repo.insert!(%Generator{
        p_max_mw: 1000.0,
        summer_capacity_mw: 1000.0,
        fuel_type: "SUN",
        status: "retired",
        bus_id: bus.id
      })

      measured_solar("CISO", 500.0)

      assert [entry] = BtmSolar.output_at(entries(bus, 10.0), @hour)
      assert_in_delta entry.output_mw, 5.0, 1.0e-9
    end
  end

  describe "output_at/3 clamping" do
    test "a capacity factor above 1 is clamped — rooftop cannot exceed its nameplate", %{
      bus: bus
    } do
      # Measured generation can exceed the mapped fleet's capability whenever
      # units are missing from the network (ENE-15 territory). Left unclamped
      # that would hand the cascade more rooftop MW than exist.
      solar_fleet(bus, 100.0)
      measured_solar("CISO", 450.0)

      assert [entry] = BtmSolar.output_at(entries(bus, 20.0), @hour)
      assert_in_delta entry.output_mw, 20.0, 1.0e-9
    end

    test "negative net generation clamps to zero, never to negative rooftop output", %{
      bus: bus
    } do
      solar_fleet(bus, 100.0)
      measured_solar("CISO", -5.0)

      assert [entry] = BtmSolar.output_at(entries(bus, 20.0), @hour)
      assert entry.output_mw == 0.0
    end
  end

  describe "output_at/3 nil safety" do
    test "no hour requested yields zero output", %{bus: bus} do
      solar_fleet(bus, 100.0)
      measured_solar("CISO", 50.0)

      assert [entry] = BtmSolar.output_at(entries(bus, 20.0), nil)
      assert entry.output_mw == 0.0
      assert entry.capacity_mw == 20.0
    end

    test "a BA with no fuel row for the hour yields zero output", %{bus: bus} do
      solar_fleet(bus, 100.0)
      measured_solar("CISO", 50.0, ~U[2024-07-15 18:00:00Z])

      assert [entry] = BtmSolar.output_at(entries(bus, 20.0), @hour)
      assert entry.output_mw == 0.0
    end

    test "a BA with no solar capability yields zero rather than dividing by zero", %{
      bus: bus
    } do
      measured_solar("CISO", 50.0)

      assert [entry] = BtmSolar.output_at(entries(bus, 20.0), @hour)
      assert entry.output_mw == 0.0
    end

    test "a bus with no balancing authority yields zero output" do
      orphan = Repo.insert!(%Bus{bus_type: 1, base_kv: 138.0})
      measured_solar("CISO", 50.0)

      assert [entry] = BtmSolar.output_at(entries(orphan, 20.0), @hour)
      assert entry.output_mw == 0.0
    end

    test "rows stranded by a deleted bus are dropped, not returned with a nil bus" do
      assert BtmSolar.output_at([%{bus_id: nil, sector: "residential", capacity_mw: 9.0}], @hour) ==
               []
    end

    test "an empty entry list short-circuits" do
      assert BtmSolar.output_at([], @hour) == []
    end
  end

  describe "legacy_fraction/0" do
    test "defaults to the documented 30% IEEE 1547-2003 share", %{bus: bus} do
      assert BtmSolar.legacy_fraction() == 0.30

      assert [%{legacy_fraction: 0.30}] = BtmSolar.output_at(entries(bus, 1.0), nil)
    end

    test "is configurable, and a nonsense value falls back to a usable fraction" do
      Application.put_env(:power_model, :btm_legacy_fraction, 0.65)
      on_exit(fn -> Application.delete_env(:power_model, :btm_legacy_fraction) end)

      assert BtmSolar.legacy_fraction() == 0.65

      Application.put_env(:power_model, :btm_legacy_fraction, 1.8)
      assert BtmSolar.legacy_fraction() == 1.0

      Application.put_env(:power_model, :btm_legacy_fraction, :nonsense)
      assert BtmSolar.legacy_fraction() == 0.30
    end
  end
end
