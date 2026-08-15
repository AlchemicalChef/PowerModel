defmodule PowerModel.Ingestion.EIA.Form923Test do
  use PowerModel.DataCase, async: false

  import ExUnit.CaptureLog

  alias PowerModel.Grid.Generator
  alias PowerModel.Ingestion.EIA.Form923

  @moduletag :db

  # Header cell carries an embedded newline exactly as the EIA XLSX export
  # does; the plant appears on SEVERAL rows (one per prime mover / fuel).
  @headers ["Plant Id", "Combined Heat And\nPower Plant", "Net Generation\n(Megawatthours)"]

  defp insert_gen!(attrs) do
    defaults = %{p_max_mw: 100.0, status: "in_service"}
    Repo.insert!(struct(Generator, Map.merge(defaults, attrs)))
  end

  describe "ingest_rows/1 aggregation (PLT-4)" do
    test "sums a plant's rows before computing ONE capacity factor" do
      a = insert_gen!(%{eia_plant_id: "300", generator_id: "A"})
      b = insert_gen!(%{eia_plant_id: "300", generator_id: "B"})

      # In-service capacity 200 MW -> denominator 200 * 8760 = 1,752,000 MWh.
      # Two rows for the plant, quoted with thousands separators, summing to
      # 876,000 MWh -> CF 0.5. The old per-row code computed each row against
      # whole-plant capacity and let the LAST processed row win (~0.21/~0.29).
      rows = [
        @headers,
        ["300", "N", "500,000"],
        ["300", "N", "376,000"]
      ]

      assert {:ok, 1} = Form923.ingest_rows(rows)

      assert Repo.reload!(a).capacity_factor == 0.5
      assert Repo.reload!(b).capacity_factor == 0.5
    end

    test "excludes non-in-service units from the denominator and the write" do
      live = insert_gen!(%{eia_plant_id: "301", generator_id: "A"})

      retired =
        insert_gen!(%{
          eia_plant_id: "301",
          generator_id: "OLD",
          status: "retired",
          p_max_mw: 900.0
        })

      # 100 MW in service -> 876,000 MWh denominator. 438,000 MWh -> CF 0.5.
      # Counting the 900 MW retired unit would give 0.05 instead.
      assert {:ok, 1} = Form923.ingest_rows([@headers, ["301", "N", "438,000"]])

      assert Repo.reload!(live).capacity_factor == 0.5
      assert Repo.reload!(retired).capacity_factor == nil
    end

    test "clamps the capacity factor to [0, 1]" do
      high = insert_gen!(%{eia_plant_id: "302", generator_id: "A"})
      pumped = insert_gen!(%{eia_plant_id: "303", generator_id: "A"})

      assert {:ok, 2} =
               Form923.ingest_rows([
                 @headers,
                 # far more than 100 MW * 8760 h
                 ["302", "N", "9,000,000"],
                 # net consumer (pumped storage): negative net generation
                 ["303", "N", "-50,000"]
               ])

      assert Repo.reload!(high).capacity_factor == 1.0
      assert Repo.reload!(pumped).capacity_factor == 0.0
    end

    test "plant ids are normalized from the float cell form" do
      gen = insert_gen!(%{eia_plant_id: "304", generator_id: "A"})

      assert {:ok, 1} = Form923.ingest_rows([@headers, ["304.0", "N", "87,600"]])

      assert Repo.reload!(gen).capacity_factor == 0.1
    end
  end

  describe "ingest_rows/1 header handling (PLT-4)" do
    test "warns loudly and ingests nothing when the required columns are missing" do
      gen = insert_gen!(%{eia_plant_id: "305", generator_id: "A"})

      log =
        capture_log(fn ->
          assert {:error, :headers_not_found} =
                   Form923.ingest_rows([
                     ["Some Column", "Other Column"],
                     ["305", "438000"]
                   ])
        end)

      assert log =~ "required columns not found"
      assert log =~ "NO capacity factors were ingested"
      assert Repo.reload!(gen).capacity_factor == nil
    end

    test "an empty file is reported, not silently ignored" do
      log =
        capture_log(fn ->
          assert {:error, :empty_file} = Form923.ingest_rows([])
        end)

      assert log =~ "NO capacity factors were ingested"
    end
  end

  describe "ingest/1 (file entry point)" do
    @tag :tmp_dir
    test "parses a generation.csv with quoted thousands separators end-to-end",
         %{tmp_dir: tmp_dir} do
      gen = insert_gen!(%{eia_plant_id: "306", generator_id: "A"})

      File.write!(Path.join(tmp_dir, "generation.csv"), """
      Plant Id,Plant Name,Net Generation (Megawatthours)
      306,"Gavin, General James M.","438,000"
      """)

      assert {:ok, 1} = Form923.ingest(tmp_dir)
      assert Repo.reload!(gen).capacity_factor == 0.5
    end

    @tag :tmp_dir
    test "missing file warns and returns an error", %{tmp_dir: tmp_dir} do
      log =
        capture_log(fn ->
          assert {:error, :file_not_found} = Form923.ingest(tmp_dir)
        end)

      assert log =~ "no generation file"
    end
  end
end
