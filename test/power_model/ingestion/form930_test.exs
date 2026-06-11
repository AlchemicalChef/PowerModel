defmodule PowerModel.Ingestion.EIA.Form930Test do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Demand.BADemandHour
  alias PowerModel.Grid.BalancingAuthority
  alias PowerModel.Ingestion.EIA.Form930

  @fixture Path.expand("../../fixtures/eia930_balance_sample.csv", __DIR__)

  setup do
    Repo.insert!(%BalancingAuthority{code: "CISO", name: "California ISO"})
    Repo.insert!(%BalancingAuthority{code: "ERCO", name: "ERCOT"})
    :ok
  end

  defp demand_for(code, iso8601) do
    {:ok, ts, 0} = DateTime.from_iso8601(iso8601)

    Repo.one(
      from d in BADemandHour,
        join: ba in assoc(d, :balancing_authority),
        where: ba.code == ^code and d.timestamp_utc == ^ts,
        select: d.demand_mw
    )
  end

  test "ingests demand rows, skipping generation-only BAs" do
    assert {:ok, 9} = Form930.ingest_file(@fixture)

    # 4 CISO + 4 ERCO + 1 SEC; GRID has no demand and is skipped entirely
    assert Repo.aggregate(BADemandHour, :count) == 9
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
    {:ok, 9} = Form930.ingest_file(@fixture)

    # Corrupt one value, re-ingest, confirm it is restored and nothing duplicated
    {:ok, ts, 0} = DateTime.from_iso8601("2024-07-15T17:00:00Z")

    from(d in BADemandHour, where: d.timestamp_utc == ^ts)
    |> Repo.update_all(set: [demand_mw: 1.0])

    {:ok, 9} = Form930.ingest_file(@fixture)

    assert Repo.aggregate(BADemandHour, :count) == 9
    assert demand_for("CISO", "2024-07-15T17:00:00Z") == 41_123.0
  end

  test "directory ingest globs EIA930_BALANCE_*.csv" do
    tmp = Path.join(System.tmp_dir!(), "eia930_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.cp!(@fixture, Path.join(tmp, "EIA930_BALANCE_2024_Jul_Dec.csv"))

    try do
      assert {:ok, 9} = Form930.ingest(tmp)
    after
      File.rm_rf!(tmp)
    end
  end
end
