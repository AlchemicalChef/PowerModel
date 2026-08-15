defmodule PowerModel.Ingestion.EIA.Form861Test do
  use PowerModel.DataCase, async: false

  alias PowerModel.Grid.BtmSolar
  alias PowerModel.Ingestion.EIA.Form861

  doctest PowerModel.Ingestion.EIA.Form861, import: true

  @fixtures Path.expand("../../fixtures/eia861", __DIR__)

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!()

  describe "parse_net_metering/1 (3 stacked header rows)" do
    test "reads PV capacity, not the identically-labelled Wind columns" do
      # The fixture keeps the real header block through the Wind group. "Capacity
      # MW / Residential" appears under BOTH Photovoltaic (col 6) and Wind
      # (col 71); a leaf-only column match would silently read Wind.
      assert {:ok, rows} = Form861.parse_net_metering(fixture("net_metering_states_mini.csv"))

      alaska_power =
        rows
        |> Enum.filter(&(&1.utility_id == "219"))
        |> Map.new(&{&1.sector, &1.capacity_mw})

      # Row for utility 219: PV capacity MW residential 0.011, commercial 0.02,
      # industrial "." (withheld).
      assert alaska_power == %{"residential" => 0.011, "commercial" => 0.02}
    end

    test "splits each utility row into one entry per sector, tagged with the state" do
      assert {:ok, rows} = Form861.parse_net_metering(fixture("net_metering_states_mini.csv"))

      assert Enum.all?(rows, &(&1.state == "AK"))
      assert Enum.all?(rows, &(&1.sector in BtmSolar.sectors()))
      assert Enum.all?(rows, &(&1.capacity_mw > 0.0))
    end

    test "fails loudly when the expected column path is absent" do
      # A future 861 that renames the technology group must not parse as zero.
      csv =
        fixture("net_metering_states_mini.csv")
        |> String.replace("Photovoltaic", "Solar Photovoltaics", global: false)

      assert {:error, {sector, {:path_not_found, path}}} = Form861.parse_net_metering(csv)
      assert sector in BtmSolar.sectors()
      assert {:prefix, "photovoltaic"} in path
    end

    test "rejects a sheet with no data rows rather than reporting an empty fleet" do
      assert {:error, :sheet_too_short} = Form861.parse_net_metering("a,b\nc,d\n")
    end
  end

  describe "parse_non_net_metering/1 (2 stacked header rows)" do
    test "reads the PV group's sector columns, not Battery's" do
      assert {:ok, rows} = Form861.parse_non_net_metering(fixture("non_net_metering_mini.csv"))

      by_utility =
        rows
        |> Enum.group_by(& &1.utility_id)
        |> Map.new(fn {u, rs} -> {u, Map.new(rs, &{&1.sector, &1.capacity_mw})} end)

      assert by_utility["213"] == %{"commercial" => 0.09}
      assert by_utility["221"] == %{"residential" => 0.038, "commercial" => 1.083}
    end

    test "excludes Direct Connected capacity, which is not behind a meter" do
      assert {:ok, rows} = Form861.parse_non_net_metering(fixture("non_net_metering_mini.csv"))

      # Utility 219 reports 0.093 commercial + 0.062 direct connected = 0.155
      # total. Only the 0.093 is behind-the-meter.
      assert [%{capacity_mw: 0.093, sector: "commercial"}] =
               Enum.filter(rows, &(&1.utility_id == "219"))
    end
  end

  describe "parse_service_territory/1" do
    test "groups counties by utility and state" do
      assert {:ok, territories} =
               Form861.parse_service_territory(fixture("service_territory_mini.csv"))

      # A & N Electric Coop straddles a state line: its two Virginia counties
      # and its one Maryland county are separate entries, because 861 reports
      # capacity per state too.
      assert Enum.sort(territories[{"84", "VA"}]) == ["Accomack", "Northampton"]
      assert territories[{"84", "MD"}] == ["Somerset"]
      assert territories[{"34", "SC"}] == ["Abbeville"]
    end
  end

  describe "county name matching" do
    test "folds diacritics so EIA's ASCII reaches the Census spelling" do
      assert Form861.index_key("Doña Ana County") == {"donaana", false}
      assert Form861.lookup_keys("Dona Ana") == [{"donaana", false}]
    end

    test "strips county-type suffixes" do
      assert Form861.index_key("Autauga County") == {"autauga", false}
      assert Form861.index_key("Vermilion Parish") == {"vermilion", false}
      assert Form861.index_key("Nome Census Area") == {"nome", false}
      assert Form861.index_key("Anchorage Municipality") == {"anchorage", false}
    end

    test "a Virginia independent city indexes apart from the county of the same name" do
      assert Form861.index_key("Roanoke city") == {"roanoke", true}
      assert Form861.index_key("Roanoke County") == {"roanoke", false}
    end

    test "\"City\" in an 861 name is tried as an independent city first, then literally" do
      # "Roanoke City" IS the independent city; "James City" is James City
      # COUNTY, which has no independent city to shadow it. One ordered
      # candidate list resolves both.
      assert [{"roanoke", true} | _] = Form861.lookup_keys("Roanoke City")

      assert Form861.lookup_keys("James City") == [
               {"james", true},
               {"jamescity", false},
               {"james", false}
             ]
    end

    test "\"City and Borough\" loses the whole phrase and stays a county" do
      assert Form861.index_key("Juneau City and Borough") == {"juneau", false}
    end
  end

  describe "allocate/4" do
    # Two counties, two utilities, one of which serves both.
    defp counties do
      %{
        "001" => %{population: 300, state: "CA"},
        "002" => %{population: 100, state: "CA"}
      }
    end

    defp shares do
      %{"001" => [{1, 0.75}, {2, 0.25}], "002" => [{3, 1.0}]}
    end

    defp capacity(utility, sector, mw),
      do: %{utility_id: utility, state: "CA", sector: sector, capacity_mw: mw}

    test "splits a utility's capacity across its counties by population" do
      territories = %{{"A", "CA"} => ["001", "002"]}
      rows = [capacity("A", "residential", 400.0)]

      {allocated, report} = Form861.allocate(rows, territories, counties(), shares())

      by_bus = Map.new(allocated, &{&1.bus_id, &1.capacity_mw})

      # County 001 holds 300/400 of the population -> 300 MW, split 0.75/0.25
      # across its two buses; county 002 takes the remaining 100 MW.
      assert_in_delta by_bus[1], 225.0, 1.0e-9
      assert_in_delta by_bus[2], 75.0, 1.0e-9
      assert_in_delta by_bus[3], 100.0, 1.0e-9
      assert_in_delta report.allocated_mw, 400.0, 1.0e-9
    end

    test "capacity is conserved from utility through county to bus" do
      territories = %{{"A", "CA"} => ["001", "002"], {"B", "CA"} => ["001"]}

      rows = [
        capacity("A", "residential", 400.0),
        capacity("B", "residential", 60.0),
        capacity("A", "commercial", 40.0)
      ]

      {allocated, report} = Form861.allocate(rows, territories, counties(), shares())

      total = allocated |> Enum.map(& &1.capacity_mw) |> Enum.sum()

      assert_in_delta total, 500.0, 1.0e-9
      assert_in_delta report.total_mw, 500.0, 1.0e-9
      assert_in_delta report.unallocated_mw, 0.0, 1.0e-9
    end

    test "a county served by two utilities receives both, summed into one row" do
      territories = %{{"A", "CA"} => ["001"], {"B", "CA"} => ["001"]}

      rows = [capacity("A", "residential", 100.0), capacity("B", "residential", 300.0)]

      {allocated, _report} = Form861.allocate(rows, territories, counties(), shares())

      # The unique index is [bus_id, sector], so bus 1 must carry ONE row
      # holding both utilities' capacity: 0.75 * (100 + 300).
      assert [bus1] = Enum.filter(allocated, &(&1.bus_id == 1))
      assert_in_delta bus1.capacity_mw, 300.0, 1.0e-9

      # Provenance names the larger contributor.
      assert bus1.utility_id == "B"
    end

    test "a utility with no matched territory spreads across its whole state" do
      rows = [capacity("Unmapped", "residential", 400.0)]

      {allocated, report} = Form861.allocate(rows, %{}, counties(), shares())

      total = allocated |> Enum.map(& &1.capacity_mw) |> Enum.sum()

      assert_in_delta total, 400.0, 1.0e-9
      assert_in_delta report.state_fallback_mw, 400.0, 1.0e-9
      assert_in_delta report.no_territory_mw, 0.0, 1.0e-9
    end

    test "capacity in a state with no counties at all is reported, not silently dropped" do
      rows = [%{utility_id: "A", state: "PR", sector: "residential", capacity_mw: 34.0}]

      {allocated, report} = Form861.allocate(rows, %{}, counties(), shares())

      assert allocated == []
      assert_in_delta report.no_territory_mw, 34.0, 1.0e-9
      assert_in_delta report.unallocated_mw, 34.0, 1.0e-9
    end

    test "a county that reaches no bus is counted as unallocatable" do
      territories = %{{"A", "CA"} => ["001", "002"]}
      rows = [capacity("A", "residential", 400.0)]

      # County 002 has no buses within reach.
      {allocated, report} =
        Form861.allocate(rows, territories, counties(), %{"001" => [{1, 1.0}]})

      assert [%{bus_id: 1, capacity_mw: 300.0}] = allocated
      assert_in_delta report.no_bus_mw, 100.0, 1.0e-9
      assert_in_delta report.unallocated_mw, 100.0, 1.0e-9
    end

    test "unpopulated counties split evenly rather than dropping the capacity" do
      counties = %{"001" => %{population: 0, state: "CA"}, "002" => %{population: 0, state: "CA"}}
      territories = %{{"A", "CA"} => ["001", "002"]}

      {allocated, _report} =
        Form861.allocate([capacity("A", "residential", 100.0)], territories, counties, shares())

      by_bus = Map.new(allocated, &{&1.bus_id, &1.capacity_mw})

      assert_in_delta by_bus[1], 37.5, 1.0e-9
      assert_in_delta by_bus[3], 50.0, 1.0e-9
    end
  end

  describe "replace_all/1 (idempotency)" do
    @describetag :db

    setup do
      bus = Repo.insert!(%PowerModel.Grid.Bus{bus_type: 1, base_kv: 138.0})
      %{bus: bus}
    end

    test "re-running rebuilds the table instead of accumulating", %{bus: bus} do
      rows = [
        %{bus_id: bus.id, sector: "residential", capacity_mw: 5.0, state: "CA", utility_id: "A"},
        %{bus_id: bus.id, sector: "commercial", capacity_mw: 2.0, state: "CA", utility_id: "A"}
      ]

      assert {:ok, 2} = Form861.replace_all(rows)
      assert {:ok, 2} = Form861.replace_all(rows)

      assert Repo.aggregate(BtmSolar, :count) == 2
      assert Repo.one(from s in BtmSolar, select: sum(s.capacity_mw)) == 7.0
    end

    test "a shrinking allocation leaves no stranded rows behind", %{bus: bus} do
      first = [
        %{bus_id: bus.id, sector: "residential", capacity_mw: 5.0, state: "CA", utility_id: "A"},
        %{bus_id: bus.id, sector: "industrial", capacity_mw: 1.0, state: "CA", utility_id: "A"}
      ]

      assert {:ok, 2} = Form861.replace_all(first)

      assert {:ok, 1} =
               Form861.replace_all([
                 %{
                   bus_id: bus.id,
                   sector: "residential",
                   capacity_mw: 5.0,
                   state: "CA",
                   utility_id: "A"
                 }
               ])

      assert Repo.all(from s in BtmSolar, select: s.sector) == ["residential"]
    end
  end
end
