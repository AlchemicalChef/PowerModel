defmodule PowerModel.Ingestion.EPA.EGridTest do
  use PowerModel.DataCase, async: false

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

      assert {:ok, plant_cfs} = EGrid.parse_gen_sheet(csv)
      assert plant_cfs == %{"8102" => 0.8}
    end

    test "capacity-weights unit CFs within a plant" do
      csv =
        gen_csv([
          "1,10,Plant A,1,0.9,300",
          "2,10,Plant A,2,0.1,100"
        ])

      assert {:ok, %{"10" => cf}} = EGrid.parse_gen_sheet(csv)
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

      assert {:ok, %{"20" => cf}} = EGrid.parse_gen_sheet(csv)
      assert_in_delta cf, 0.75, 1.0e-9
    end

    test "all-nonpositive plants resolve to 0.0, not dropped and not floored (PLT-9)" do
      csv =
        gen_csv([
          "1,30,Idle Plant,1,0.0,200",
          "2,30,Idle Plant,2,-0.2,100"
        ])

      assert {:ok, plant_cfs} = EGrid.parse_gen_sheet(csv)
      # Present (would previously be skipped, leaving CF NULL -> 100%
      # dispatch), exactly 0.0 (previously floored at 0.01).
      assert Map.fetch!(plant_cfs, "30") == 0.0
    end

    test "units without a CFACT are skipped; zero-capacity units fall back to a simple mean" do
      csv =
        gen_csv([
          "1,40,Plant C,1,,500",
          "2,40,Plant C,2,0.6,0",
          "3,40,Plant C,3,0.4,0"
        ])

      assert {:ok, %{"40" => cf}} = EGrid.parse_gen_sheet(csv)
      assert_in_delta cf, 0.5, 1.0e-9
    end

    test "ORISPL float cell form is normalized to the stored integer string" do
      csv = gen_csv(["1,613.0,Plant D,1,0.5,100"])

      assert {:ok, plant_cfs} = EGrid.parse_gen_sheet(csv)
      assert Map.has_key?(plant_cfs, "613")
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
        Repo.insert!(%Generator{
          eia_plant_id: "50",
          generator_id: gid,
          p_max_mw: 100.0,
          status: "in_service"
        })
      end

      assert EGrid.apply_plant_capacity_factors(%{"50" => 0.42}) == 2

      cfs =
        Repo.all(from g in Generator, where: g.eia_plant_id == "50", select: g.capacity_factor)

      assert cfs == [0.42, 0.42]
    end
  end
end
