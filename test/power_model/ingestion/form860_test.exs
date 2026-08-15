defmodule PowerModel.Ingestion.EIA.Form860Test do
  use PowerModel.DataCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias PowerModel.Grid.Generator
  alias PowerModel.Ingestion.EIA.Form860

  defp write_fixtures(dir, gen1_capacity, gen1_status) do
    File.write!(Path.join(dir, "generators.csv"), """
    Plant Code,Generator ID,Energy Source 1,Prime Mover,Nameplate Capacity (MW),Minimum Load (MW),Status
    100,GEN1,NUC,ST,#{gen1_capacity},500,#{gen1_status}
    100,GEN2,NG,CT,500,100,OP
    200,1,SUB,ST,600,200,OP
    """)

    File.write!(Path.join(dir, "2___Plant_Y2024.csv"), """
    Plant Code,Latitude,Longitude
    100,35.0,-90.0
    200,40.0,-100.0
    """)
  end

  defp insert_gen!(attrs) do
    defaults = %{p_max_mw: 100.0, status: "in_service"}
    Repo.insert!(struct(Generator, Map.merge(defaults, attrs)))
  end

  describe "parse_status/1" do
    test "OP / OPERATING map to in_service" do
      assert Form860.parse_status("OP") == "in_service"
      assert Form860.parse_status("OPERATING") == "in_service"
      # tolerant of surrounding whitespace and case
      assert Form860.parse_status(" op ") == "in_service"
    end

    test "SB maps to standby (available, but not counted toward the load baseline)" do
      assert Form860.parse_status("SB") == "standby"
    end

    test "OA (out of service, expected to return) maps to standby, not the unknown path" do
      # 203 units / 7.2 GW carry OA: the unit exists and returns to service
      # within the calendar year. It must be kept (like SB), not treated as an
      # unrecognized code.
      log =
        capture_log(fn ->
          assert Form860.parse_status("OA") == "standby"
          assert Form860.parse_status(" oa ") == "standby"
        end)

      refute log =~ "unrecognized"
    end

    test "OS (out of service) is not in service" do
      assert Form860.parse_status("OS") == "out_of_service"
      refute Form860.parse_status("OS") == "in_service"
    end

    test "RE maps to retired" do
      assert Form860.parse_status("RE") == "retired"
      refute Form860.parse_status("RE") == "in_service"
    end

    test "planned / proposed / under-construction / cancelled codes are not in service" do
      # These units are not currently generating; counting them would inflate
      # the synthetic load baseline (85% of in-service nameplate).
      for code <- ~w(TS T U V L P OT CN) do
        assert Form860.parse_status(code) == "out_of_service",
               "expected #{code} to be out_of_service"

        refute Form860.parse_status(code) == "in_service"
      end
    end

    test "unknown code defaults to not-in-service and logs a warning with the code" do
      log =
        capture_log(fn ->
          assert Form860.parse_status("ZZ") == "out_of_service"
        end)

      assert log =~ "ZZ"
      assert log =~ "out_of_service"
    end

    test "missing status (nil or blank) defaults to in_service without warning" do
      # The Schedule 3.1 file lists existing units; an absent column or blank
      # cell is assumed operating rather than silently dropped.
      log =
        capture_log(fn ->
          assert Form860.parse_status(nil) == "in_service"
          assert Form860.parse_status("") == "in_service"
          assert Form860.parse_status("   ") == "in_service"
        end)

      refute log =~ "unrecognized"
    end
  end

  describe "categorize_fuel/2 and default_capacity_factor/2" do
    test "recognizes stored EIA fuel codes" do
      assert Form860.categorize_fuel("NUC", "ST") == "nuclear"

      for coal <- ~w(BIT SUB LIG RC WC) do
        assert Form860.categorize_fuel(coal, "ST") == "coal"
      end

      assert Form860.categorize_fuel("DFO", "IC") == "oil"
      assert Form860.categorize_fuel("RFO", "ST") == "oil"
      assert Form860.categorize_fuel("WAT", "HY") == "hydro"
      assert Form860.categorize_fuel("WND", "WT") == "wind"
      assert Form860.categorize_fuel("SUN", "PV") == "solar"
      assert Form860.categorize_fuel("MWH", "BA") == "storage"
      assert Form860.categorize_fuel("GEO", "ST") == "geothermal"
    end

    test "gas splits combined cycle from simple-cycle peakers by prime mover" do
      # CC/CA/CT/CS are all combined-cycle prime movers (CT = the CC
      # combustion-turbine part); GT/IC are simple-cycle peakers.
      for pm <- ~w(CC CA CT CS) do
        assert Form860.categorize_fuel("NG", pm) == "gas_cc"
      end

      for pm <- ~w(GT IC ST) do
        assert Form860.categorize_fuel("NG", pm) == "gas_ct"
      end

      assert Form860.default_capacity_factor("NG", "CC") == 0.55
      assert Form860.default_capacity_factor("NG", "GT") == 0.12
    end

    test "unknown or missing fuel is 'other' with a mid-range default" do
      assert Form860.categorize_fuel("XYZ", "ST") == "other"
      assert Form860.categorize_fuel(nil, nil) == "other"
      assert Form860.default_capacity_factor("XYZ", nil) == 0.40
    end

    test "fuel-typical defaults match the documented constants" do
      assert Form860.default_capacity_factor("NUC", "ST") == 0.93
      assert Form860.default_capacity_factor("SUB", "ST") == 0.50
      assert Form860.default_capacity_factor("DFO", "IC") == 0.10
      assert Form860.default_capacity_factor("WAT", "HY") == 0.40
      assert Form860.default_capacity_factor("WND", "WT") == 0.35
      assert Form860.default_capacity_factor("SUN", "PV") == 0.25
      assert Form860.default_capacity_factor("MWH", "BA") == 0.10
      assert Form860.default_capacity_factor("GEO", "ST") == 0.70
    end
  end

  describe "ingest/1 file requirements" do
    @tag :tmp_dir
    test "raises an actionable error when the Plant (coordinates) file is missing",
         %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "generators.csv"), """
      Plant Code,Generator ID,Energy Source 1,Prime Mover,Nameplate Capacity (MW),Status
      100,GEN1,NUC,ST,1000,OP
      """)

      err = assert_raise RuntimeError, fn -> Form860.ingest(tmp_dir) end

      # Message must name the expected file and the consequence.
      assert err.message =~ "Plant file not found"
      assert err.message =~ "2___Plant_Y2024.csv"
      assert err.message =~ "coordinates"
    end

    @tag :tmp_dir
    test "still reports missing generator file as an error", %{tmp_dir: tmp_dir} do
      assert {:error, message} = Form860.ingest(tmp_dir)
      assert message =~ "No EIA-860 generator file"
    end
  end

  describe "ingest/1 identity and re-ingest (db)" do
    @describetag :db

    @tag :tmp_dir
    test "captures the EIA Generator ID and re-ingest updates in place", %{tmp_dir: tmp_dir} do
      write_fixtures(tmp_dir, 1000, "OP")
      capture_io(fn -> assert :ok = Form860.ingest(tmp_dir) end)

      assert Repo.aggregate(Generator, :count) == 3

      gen1 = Repo.get_by!(Generator, eia_plant_id: "100", generator_id: "GEN1")
      assert gen1.p_max_mw == 1000.0
      assert gen1.status == "in_service"
      # Coordinates came from the Plant file
      assert %Geo.Point{coordinates: {-90.0, 35.0}} = gen1.coordinates

      # Simulate a later measured CF (EIA-923 / eGRID) that must survive
      # a re-ingest.
      Repo.update_all(from(g in Generator, where: g.generator_id == "GEN1"),
        set: [capacity_factor: 0.77]
      )

      # Re-ingest with a changed capacity and status for GEN1: the fleet must
      # NOT double; GEN1 is updated in place.
      write_fixtures(tmp_dir, 1100, "SB")
      capture_io(fn -> assert :ok = Form860.ingest(tmp_dir) end)

      assert Repo.aggregate(Generator, :count) == 3,
             "re-ingest must not duplicate generators"

      gen1 = Repo.get_by!(Generator, eia_plant_id: "100", generator_id: "GEN1")
      assert gen1.p_max_mw == 1100.0
      assert gen1.status == "standby"
      # Measured CF survives the upsert (not in the replace list)
      assert gen1.capacity_factor == 0.77
    end

    @tag :tmp_dir
    test "ingest leaves no generator with a NULL capacity factor", %{tmp_dir: tmp_dir} do
      write_fixtures(tmp_dir, 1000, "OP")
      capture_io(fn -> assert :ok = Form860.ingest(tmp_dir) end)

      assert Repo.one(from g in Generator, where: is_nil(g.capacity_factor), select: count()) == 0

      # Fuel-typical defaults: NUC 0.93; NG + CT prime mover = combined cycle
      # 0.55; SUB (subbituminous coal) 0.50 — not the gas bucket.
      assert Repo.get_by!(Generator, generator_id: "GEN1").capacity_factor == 0.93
      assert Repo.get_by!(Generator, generator_id: "GEN2").capacity_factor == 0.55
      assert Repo.get_by!(Generator, eia_plant_id: "200").capacity_factor == 0.50
    end
  end

  describe "backfill_missing_capacity_factors/0 (db)" do
    @describetag :db

    test "fills only NULL capacity factors with fuel-typical defaults and logs MW" do
      nuke =
        insert_gen!(%{eia_plant_id: "1", fuel_type: "NUC", prime_mover: "ST", p_max_mw: 900.0})

      coal = insert_gen!(%{eia_plant_id: "2", fuel_type: "SUB", prime_mover: "ST"})
      peaker = insert_gen!(%{eia_plant_id: "3", fuel_type: "NG", prime_mover: "GT"})
      storage = insert_gen!(%{eia_plant_id: "4", fuel_type: "MWH", prime_mover: "BA"})
      unknown = insert_gen!(%{eia_plant_id: "5", fuel_type: "XYZ", prime_mover: nil})

      measured =
        insert_gen!(%{
          eia_plant_id: "6",
          fuel_type: "NUC",
          prime_mover: "ST",
          capacity_factor: 0.61
        })

      output = capture_io(fn -> assert Form860.backfill_missing_capacity_factors() == 5 end)

      assert Repo.reload!(nuke).capacity_factor == 0.93
      assert Repo.reload!(coal).capacity_factor == 0.50
      assert Repo.reload!(peaker).capacity_factor == 0.12
      assert Repo.reload!(storage).capacity_factor == 0.10
      assert Repo.reload!(unknown).capacity_factor == 0.40
      # A measured CF is never overwritten by the default pass
      assert Repo.reload!(measured).capacity_factor == 0.61

      # MW backfilled is reported per fuel category
      assert output =~ "nuclear"
      assert output =~ "900.0 MW"
    end

    test "is a no-op when every generator already has a capacity factor" do
      insert_gen!(%{eia_plant_id: "7", fuel_type: "NUC", capacity_factor: 0.9})
      capture_io(fn -> assert Form860.backfill_missing_capacity_factors() == 0 end)
    end
  end
end
