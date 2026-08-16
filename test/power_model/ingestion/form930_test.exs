defmodule PowerModel.Ingestion.EIA.Form930Test do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Demand.{BADemandHour, BAFuelHour}
  alias PowerModel.Grid.BalancingAuthority
  alias PowerModel.Ingestion.EIA.Form930

  @fixture Path.expand("../../fixtures/eia930_balance_sample.csv", __DIR__)
  @fuels_fixture Path.expand("../../fixtures/eia930_balance_fuels_sample.csv", __DIR__)
  @legacy_fuels_fixture Path.expand(
                          "../../fixtures/eia930_balance_legacy_fuels_sample.csv",
                          __DIR__
                        )

  setup do
    Repo.insert!(%BalancingAuthority{code: "CISO", name: "California ISO"})
    Repo.insert!(%BalancingAuthority{code: "ERCO", name: "ERCOT"})
    :ok
  end

  defp demand_for(code, iso8601) do
    case demand_row(code, iso8601) do
      nil -> nil
      row -> row.demand_mw
    end
  end

  defp demand_row(code, iso8601) do
    {:ok, ts, 0} = DateTime.from_iso8601(iso8601)

    Repo.one(
      from d in BADemandHour,
        join: ba in assoc(d, :balancing_authority),
        where: ba.code == ^code and d.timestamp_utc == ^ts
    )
  end

  test "keeps a generation-only BA's row for its generation and interchange" do
    assert {:ok, 11} = Form930.ingest_file(@fixture)

    # 4 CISO + 4 ERCO + 1 SEC + 2 GRID. REVIEW ENE-20 (ENE20-E): GRID leaves
    # the demand cell blank, and dropping the whole row for that threw away
    # the net generation and interchange published beside it — the only
    # anchor a generation-only BA's injection has.
    assert Repo.aggregate(BADemandHour, :count) == 11

    # Stored at hour start, so this is the row whose UTC end is 19:00.
    row = demand_row("GRID", "2024-07-15T18:00:00Z")
    assert row.demand_mw == nil
    assert row.net_generation_mw == 618.0
    assert row.total_interchange_mw == 618.0
  end

  test "a row with none of the three series is still dropped" do
    {:ok, _} = Form930.ingest_file(@fixture)

    # Nothing in the fixture is blank across all three, so every ingested row
    # carries at least one number — an all-blank row would carry no data at
    # all and has nothing to contribute.
    assert Repo.all(
             from d in BADemandHour,
               where:
                 is_nil(d.demand_mw) and is_nil(d.net_generation_mw) and
                   is_nil(d.total_interchange_mw)
           ) == []
  end

  test "prefers adjusted demand, falls back to raw when adjusted is blank" do
    {:ok, _} = Form930.ingest_file(@fixture)

    # Adjusted "41,123" preferred over raw "41,000" (thousands separator parsed)
    assert demand_for("CISO", "2024-07-15T17:00:00Z") == 41_123.0
    # Adjusted blank at 20:00 -> raw "44,250"
    assert demand_for("CISO", "2024-07-15T19:00:00Z") == 44_250.0
  end

  test "parses US-format UTC timestamps" do
    {:ok, _} = Form930.ingest_file(@fixture)

    # ERCO rows use "7/15/2024 6:00:00 PM" style UTC timestamps
    assert demand_for("ERCO", "2024-07-15T17:00:00Z") == 76_200.0
    assert demand_for("ERCO", "2024-07-15T20:00:00Z") == 81_900.0
  end

  test "creates BAs present in 930 but absent from the database" do
    {:ok, _} = Form930.ingest_file(@fixture)

    sec = Repo.get_by(BalancingAuthority, code: "SEC")
    assert sec != nil
    assert sec.name == "SEC"
    assert demand_for("SEC", "2024-07-15T17:00:00Z") == 1_250.0
  end

  test "re-ingestion is idempotent and refreshes values" do
    {:ok, 11} = Form930.ingest_file(@fixture)

    # Corrupt one value, re-ingest, confirm it is restored and nothing duplicated
    {:ok, ts, 0} = DateTime.from_iso8601("2024-07-15T17:00:00Z")

    from(d in BADemandHour, where: d.timestamp_utc == ^ts)
    |> Repo.update_all(set: [demand_mw: 1.0])

    {:ok, 11} = Form930.ingest_file(@fixture)

    assert Repo.aggregate(BADemandHour, :count) == 11
    assert demand_for("CISO", "2024-07-15T17:00:00Z") == 41_123.0
  end

  describe "per-fuel ingestion" do
    defp fuel_mw(code, iso8601, fuel) do
      {:ok, ts, 0} = DateTime.from_iso8601(iso8601)

      Repo.one(
        from f in BAFuelHour,
          where: f.ba_code == ^code and f.timestamp_utc == ^ts and f.fuel == ^fuel,
          select: f.net_generation_mw
      )
    end

    defp fuels_for(code, iso8601) do
      {:ok, ts, 0} = DateTime.from_iso8601(iso8601)

      Repo.all(
        from f in BAFuelHour,
          where: f.ba_code == ^code and f.timestamp_utc == ^ts,
          select: f.fuel
      )
      |> Enum.sort()
    end

    test "stores one row per reported fuel, on the hour-START timestamp" do
      {:ok, _} = Form930.ingest_file(@fuels_fixture)

      # Row is timestamped 19:00 END of hour, so it is stored at 18:00 -- the
      # same convention as the demand rows it accompanies.
      assert fuel_mw("CISO", "2024-07-15T18:00:00Z", "coal") == 1_000.0
      assert fuel_mw("CISO", "2024-07-15T18:00:00Z", "natural_gas") == 12_000.0
      assert fuel_mw("CISO", "2024-07-15T18:00:00Z", "nuclear") == 2_240.0
      assert fuel_mw("CISO", "2024-07-15T18:00:00Z", "hydro") == 3_000.0
      assert demand_for("CISO", "2024-07-15T18:00:00Z") == 41_123.0
    end

    test "sums the split storage columns into one solar and one wind row" do
      {:ok, _} = Form930.ingest_file(@fuels_fixture)

      # 8,000 without battery + 250 with battery
      assert fuel_mw("CISO", "2024-07-15T18:00:00Z", "solar") == 8_250.0
      # 1,500 without battery + 100 with battery
      assert fuel_mw("CISO", "2024-07-15T18:00:00Z", "wind") == 1_600.0
    end

    test "resolves EIA's two malformed header names" do
      {:ok, _} = Form930.ingest_file(@fuels_fixture)

      # "other" = pumped storage (-500, header has a DOUBLE SPACE before the
      # suffix) + battery (-300) + geothermal (900) + other fuels (200). The
      # 250 MW with-battery solar column ("Solar witho ...", EIA's typo for
      # "with") must land in solar, never in "other" and never be dropped.
      assert fuel_mw("CISO", "2024-07-15T18:00:00Z", "other") == 300.0
      assert fuel_mw("CISO", "2024-07-15T18:00:00Z", "solar") == 8_250.0
    end

    test "records only fuels the BA reported, using canonical values" do
      {:ok, _} = Form930.ingest_file(@fuels_fixture)

      # Petroleum is blank for CISO -- a 0.0 row would claim coverage the file
      # does not have.
      assert fuels_for("CISO", "2024-07-15T18:00:00Z") ==
               ~w(coal hydro natural_gas nuclear other solar wind)

      # ERCO reports no hydro and no geothermal
      assert fuels_for("ERCO", "2024-07-15T18:00:00Z") ==
               ~w(coal natural_gas nuclear other solar wind)

      stored = Repo.all(from f in BAFuelHour, select: f.fuel, distinct: true)
      assert Enum.sort(stored) -- BAFuelHour.fuels() == []
    end

    test "ingests fuel rows for generation-only BAs, which report no demand" do
      {:ok, _} = Form930.ingest_file(@fuels_fixture)

      assert demand_for("GRID", "2024-07-15T18:00:00Z") == nil
      assert fuel_mw("GRID", "2024-07-15T18:00:00Z", "coal") == 620.0
    end

    test "re-ingestion refreshes fuel values without duplicating rows" do
      {:ok, _} = Form930.ingest_file(@fuels_fixture)
      before = Repo.aggregate(BAFuelHour, :count)

      Repo.update_all(BAFuelHour, set: [net_generation_mw: 1.0])
      {:ok, _} = Form930.ingest_file(@fuels_fixture)

      assert Repo.aggregate(BAFuelHour, :count) == before
      assert fuel_mw("CISO", "2024-07-15T18:00:00Z", "natural_gas") == 12_000.0
    end

    test "reads vintages that predate the storage split" do
      {:ok, _} = Form930.ingest_file(@legacy_fuels_fixture)

      assert fuel_mw("CISO", "2016-07-15T18:00:00Z", "solar") == 4_000.0
      assert fuel_mw("CISO", "2016-07-15T18:00:00Z", "wind") == 1_200.0
      # Legacy files report hydro and pumped storage in one column
      assert fuel_mw("CISO", "2016-07-15T18:00:00Z", "hydro") == 2_500.0
    end

    test "a vintage with no per-fuel columns stores no fuel rows" do
      {:ok, _} = Form930.ingest_file(@fixture)

      assert Repo.aggregate(BAFuelHour, :count) == 0
    end
  end

  test "directory ingest globs EIA930_BALANCE_*.csv" do
    tmp = Path.join(System.tmp_dir!(), "eia930_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.cp!(@fixture, Path.join(tmp, "EIA930_BALANCE_2024_Jul_Dec.csv"))

    try do
      assert {:ok, 11} = Form930.ingest(tmp)
    after
      File.rm_rf!(tmp)
    end
  end
end
