defmodule PowerModel.Ingestion.VendoredPipelineTest do
  @moduledoc """
  End to end over the committed slices of the two pinned snapshots: convert →
  ingest lines → ingest native substations → augment levels → map buses.

  The fixtures are real rows (`scripts/convert_vendored_hifld.py --limit 25`
  plus the substations those 25 lines name), so this is the national pipeline
  in miniature — including the sentinel names, the -999999 voltages, and the
  UNKNOWN<id>/TAP<id> keys that make the name match work.
  """

  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid.{Bus, Substation, TransmissionLine}
  alias PowerModel.Ingestion.BusMapper
  alias PowerModel.Ingestion.HIFLD.{Substations, TransmissionLines}

  @lines_fixture "test/fixtures/hifld/transmission_lines_mini.geojsonl"
  @substations_fixture "test/fixtures/hifld/substations_mini.geojson"

  setup do
    {:ok, lines} = TransmissionLines.ingest_geojson(@lines_fixture)
    {:ok, subs} = Substations.ingest_geojson(@substations_fixture)
    %{lines: lines, substations: subs}
  end

  test "the fixtures carry the counts the conversion produced", %{lines: lines, substations: subs} do
    # All 25 converted features: 21 carry a HIFLD voltage, 4 are restored from
    # their endpoint yards (TOPO-1).
    assert lines == 25
    assert subs == 51
    assert Repo.aggregate(TransmissionLine, :count) == 25
    assert Repo.aggregate(Substation, :count) == 51
  end

  test "most endpoints resolve by SUB_1/SUB_2 name, not by proximity" do
    Substations.augment_voltage_levels_from_lines()
    BusMapper.create_substation_buses()

    stats = BusMapper.map_transmission_line_buses()

    endpoints = 2 * Repo.aggregate(TransmissionLine, :count)
    named = Map.get(stats, :name_matched, 0)

    # Nationally this is 86% of endpoints; on this slice the substation
    # fixture was built from these very lines, so it should be higher still.
    assert named / endpoints > 0.8,
           "only #{named}/#{endpoints} endpoints resolved by name: #{inspect(stats)}"
  end

  test "every level a line terminates at has a bus by the time mapping runs" do
    Substations.augment_voltage_levels_from_lines()
    BusMapper.create_substation_buses()
    BusMapper.map_transmission_line_buses()

    # A mapped endpoint must sit on a bus within 10% of the line's own
    # voltage — the guarantee that keeps a 345 kV circuit off a 13.8 kV bus.
    mismatched =
      Repo.all(
        from l in TransmissionLine,
          join: b in Bus,
          on: b.id == l.from_bus_id,
          where: fragment("abs(? - ?) > ? * 0.1", b.base_kv, l.voltage_kv, l.voltage_kv),
          select: {l.id, l.voltage_kv, b.base_kv}
      )

    assert mismatched == []
  end

  test "the network that comes out is connected, not a pile of stubs" do
    Substations.augment_voltage_levels_from_lines()
    BusMapper.run()

    total = Repo.aggregate(Bus, :count)

    with_branch =
      Repo.one(
        from b in Bus,
          where:
            b.id in subquery(
              from l in TransmissionLine,
                where: not is_nil(l.from_bus_id),
                select: l.from_bus_id
            ) or
              b.id in subquery(
                from l in TransmissionLine,
                  where: not is_nil(l.to_bus_id),
                  select: l.to_bus_id
              ),
          select: count()
      )

    assert with_branch > 0
    # Every substation in this fixture was named by one of these lines, so
    # nearly every bus should be carrying one.
    assert with_branch / total > 0.5,
           "only #{with_branch} of #{total} buses carry a branch"
  end
end
