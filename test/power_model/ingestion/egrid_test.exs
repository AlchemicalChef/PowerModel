defmodule PowerModel.Ingestion.EPA.EGridTest do
  use PowerModel.DataCase, async: false

  import ExUnit.CaptureIO

  alias PowerModel.Grid.Generator
  alias PowerModel.Ingestion.EPA.EGrid

  # The GEN sheet as extract_sheet_to_csv/2 emits it: row 1 human-readable
  # descriptions, row 2 field names, data from row 3.
  defp gen_csv(data_rows) do
    """
    eGRID2023 unit file,,,,,
    SEQGEN,ORISPL,PNAME,GENID,CFACT,NAMEPCAP
    #{Enum.join(data_rows, "\n")}
    """
  end

  defp insert_gen!(plant_id, gen_id, p_max_mw) do
    Repo.insert!(%Generator{
      eia_plant_id: plant_id,
      generator_id: gen_id,
      p_max_mw: p_max_mw,
      status: "in_service"
    })
  end

  describe "parse_gen_sheet/1 (PLT-2 CSV parsing)" do
    test "plant names containing quoted commas do not shift columns" do
      # Regression for the hand-rolled String.split(",") parser: the comma
      # inside the quoted plant name shifted every later column, so CFACT was
      # read from the wrong cell (1,191 rows / 42.7 GW misparsed, Gavin's
      # 2,600 MW among them).
      csv =
        gen_csv([
          ~s(1,8102,"General James M. Gavin, Unit 1",1,0.85,1300),
          ~s(2,8102,"General James M. Gavin, Unit 2",2,0.75,1300)
        ])

      assert {:ok, %{plants: plants}} = EGrid.parse_gen_sheet(csv)
      assert plants == %{"8102" => 0.8}
    end

    test "capacity-weights unit CFs within a plant" do
      csv =
        gen_csv([
          "1,10,Plant A,1,0.9,300",
          "2,10,Plant A,2,0.1,100"
        ])

      assert {:ok, %{plants: %{"10" => cf}}} = EGrid.parse_gen_sheet(csv)
      assert_in_delta cf, 0.7, 1.0e-9
    end

    test "clamps each unit CFACT to [0, 1] BEFORE weighting (PLT-9)" do
      # eGRID contains CFACT values up to ~3.44; unclamped they inflate the
      # weighted sum. 3.44 must weigh in as 1.0: (1.0*100 + 0.5*100)/200.
      csv =
        gen_csv([
          "1,20,Plant B,1,3.44,100",
          "2,20,Plant B,2,0.5,100"
        ])

      assert {:ok, %{plants: %{"20" => cf}, units: units}} = EGrid.parse_gen_sheet(csv)
      assert_in_delta cf, 0.75, 1.0e-9
      # The same clamp applies to the value stored per unit.
      assert units[{"20", "1"}] == 1.0
    end

    test "all-nonpositive plants resolve to 0.0, not dropped and not floored (PLT-9)" do
      csv =
        gen_csv([
          "1,30,Idle Plant,1,0.0,200",
          "2,30,Idle Plant,2,-0.2,100"
        ])

      assert {:ok, %{plants: plants, units: units}} = EGrid.parse_gen_sheet(csv)
      # Present (would previously be skipped, leaving CF NULL -> 100%
      # dispatch), exactly 0.0 (previously floored at 0.01).
      assert Map.fetch!(plants, "30") == 0.0
      assert Map.fetch!(units, {"30", "2"}) == 0.0
    end

    test "units without a CFACT are skipped; zero-capacity units fall back to a simple mean" do
      csv =
        gen_csv([
          "1,40,Plant C,1,,500",
          "2,40,Plant C,2,0.6,0",
          "3,40,Plant C,3,0.4,0"
        ])

      assert {:ok, %{plants: %{"40" => cf}, units: units}} = EGrid.parse_gen_sheet(csv)
      assert_in_delta cf, 0.5, 1.0e-9
      # The CFACT-less unit produces no unit entry either.
      refute Map.has_key?(units, {"40", "1"})
    end

    test "ORISPL float cell form is normalized to the stored integer string" do
      csv = gen_csv(["1,613.0,Plant D,1,0.5,100"])

      assert {:ok, %{plants: plants}} = EGrid.parse_gen_sheet(csv)
      assert Map.has_key?(plants, "613")
    end

    test "missing ORISPL/CFACT columns are reported" do
      csv = """
      description row,,
      FOO,BAR,BAZ
      1,2,3
      """

      assert {:error, {:columns_not_found, _}} = EGrid.parse_gen_sheet(csv)
    end

    test "a truncated sheet is reported" do
      assert {:error, :gen_sheet_too_short} = EGrid.parse_gen_sheet("only one row\n")
    end
  end

  describe "parse_gen_sheet/1 per-unit CFs" do
    test "keeps divergent unit CFs distinct instead of collapsing to the plant mean" do
      # 31.4% of eGRID's multi-unit plants report divergent unit CFs; a plant
      # average dispatches a base-loaded unit and its idle twin identically.
      csv =
        gen_csv([
          "1,100,Two Unit Plant,1,0.9,500",
          "2,100,Two Unit Plant,2,0.1,500"
        ])

      assert {:ok, %{plants: plants, units: units}} = EGrid.parse_gen_sheet(csv)

      assert units[{"100", "1"}] == 0.9
      assert units[{"100", "2"}] == 0.1
      assert_in_delta plants["100"], 0.5, 1.0e-9
      refute units[{"100", "1"}] == plants["100"]
    end

    test "a GENID-less row feeds the plant average but yields no unit entry" do
      csv =
        gen_csv([
          "1,110,Plant E,,0.8,100",
          "2,110,Plant E,B,0.4,100"
        ])

      assert {:ok, %{plants: %{"110" => plant_cf}, units: units}} = EGrid.parse_gen_sheet(csv)
      assert_in_delta plant_cf, 0.6, 1.0e-9
      assert map_size(units) == 1
      assert units[{"110", "B"}] == 0.4
    end

    test "GENID float artifacts are normalized but real decimal IDs survive" do
      # openpyxl renders a numeric GENID cell as "1.0"; EIA-860 also issues
      # genuine IDs like "5.1" that must not be truncated.
      csv =
        gen_csv([
          "1,120,Plant F,1.0,0.5,100",
          "2,120,Plant F,5.1,0.5,100"
        ])

      assert {:ok, %{units: units}} = EGrid.parse_gen_sheet(csv)
      assert Map.has_key?(units, {"120", "1"})
      assert Map.has_key?(units, {"120", "5.1"})
    end

    test "a repeated {ORISPL, GENID} pair is capacity-weighted, not last-write-wins" do
      csv =
        gen_csv([
          "1,130,Plant G,1,1.0,300",
          "2,130,Plant G,1,0.0,100"
        ])

      assert {:ok, %{units: units}} = EGrid.parse_gen_sheet(csv)
      assert_in_delta units[{"130", "1"}], 0.75, 1.0e-9
    end
  end

  describe "apply_plant_capacity_factors/1 (db)" do
    @describetag :db

    test "stores true 0.0 for idle plants so they never dispatch at nameplate" do
      gen =
        Repo.insert!(%Generator{
          eia_plant_id: "30",
          p_max_mw: 300.0,
          status: "in_service",
          capacity_factor: nil
        })

      assert EGrid.apply_plant_capacity_factors(%{"30" => 0.0}) == 1

      # 0.0, not NULL (NULL means "dispatch at 100% of nameplate" at the
      # solver call sites) and not a 0.01 floor.
      assert Repo.reload!(gen).capacity_factor == 0.0
    end

    test "updates every generator of the plant and returns the row count" do
      for gid <- ~w(A B) do
        insert_gen!("50", gid, 100.0)
      end

      assert EGrid.apply_plant_capacity_factors(%{"50" => 0.42}) == 2

      cfs =
        Repo.all(from g in Generator, where: g.eia_plant_id == "50", select: g.capacity_factor)

      assert cfs == [0.42, 0.42]
    end
  end

  describe "apply_capacity_factors/1 (db)" do
    @describetag :db

    test "per-unit CFs land on their own units and diverge from the plant mean" do
      a = insert_gen!("100", "1", 500.0)
      b = insert_gen!("100", "2", 500.0)

      cfs = %{
        plants: %{"100" => 0.5},
        units: %{{"100", "1"} => 0.9, {"100", "2"} => 0.1}
      }

      capture_io(fn -> assert %{updated: 2, unit_rows: 2} = EGrid.apply_capacity_factors(cfs) end)

      assert Repo.reload!(a).capacity_factor == 0.9
      assert Repo.reload!(b).capacity_factor == 0.1
    end

    test "a unit the join misses keeps the plant average" do
      # Reasons a unit misses: no generator_id at all (pre-identity rows), or
      # an ID that only exists in the newer EIA-860 vintage.
      hit = insert_gen!("200", "1", 400.0)
      newer = insert_gen!("200", "3", 100.0)
      unidentified = Repo.insert!(%Generator{eia_plant_id: "200", p_max_mw: 50.0})

      cfs = %{plants: %{"200" => 0.6}, units: %{{"200", "1"} => 0.95}}

      report = capture_report(cfs)

      assert report.updated == 3
      assert report.unit_rows == 1
      assert report.fallback_rows == 2
      assert report.unit_mw == 400.0
      assert report.fallback_mw == 150.0

      assert Repo.reload!(hit).capacity_factor == 0.95
      assert Repo.reload!(newer).capacity_factor == 0.6
      assert Repo.reload!(unidentified).capacity_factor == 0.6
    end

    test "the unit pass is not gated on the plant pass having covered the plant" do
      # Real GEN-sheet output always carries the plant too, but the unit write
      # must not be conditional on it — otherwise a change to plant coverage
      # would silently take unit CFs with it.
      orphan = insert_gen!("300", "1", 200.0)

      report = capture_report(%{plants: %{}, units: %{{"300", "1"} => 0.33}})

      assert report.unit_rows == 1
      assert Repo.reload!(orphan).capacity_factor == 0.33
    end

    test "re-applying the same sheet is idempotent" do
      a = insert_gen!("400", "1", 300.0)
      b = insert_gen!("400", "2", 100.0)

      cfs = %{plants: %{"400" => 0.7}, units: %{{"400", "1"} => 0.88}}

      first = capture_report(cfs)
      second = capture_report(cfs)

      assert first == second
      assert Repo.reload!(a).capacity_factor == 0.88
      assert Repo.reload!(b).capacity_factor == 0.7
    end

    test "reports the join hit-rate in units and MW" do
      insert_gen!("500", "1", 900.0)
      insert_gen!("500", "2", 100.0)

      output =
        capture_io(fn ->
          EGrid.apply_capacity_factors(%{
            plants: %{"500" => 0.4},
            units: %{{"500", "1"} => 0.8}
          })
        end)

      assert output =~ "per-unit CFACT join: 1 of 2 eGRID-covered units (50.0%)"
      assert output =~ "900.0 of 1000.0 MW (90.0%)"
      assert output =~ "plant-average fallback: 1 units / 100.0 MW"
    end
  end

  # apply_capacity_factors/1 prints its hit-rate report; capture_io/1 runs the
  # function in the calling process, so the return value comes back by message.
  defp capture_report(cfs) do
    me = self()
    capture_io(fn -> send(me, {:report, EGrid.apply_capacity_factors(cfs)}) end)

    receive do
      {:report, report} -> report
    end
  end
end
