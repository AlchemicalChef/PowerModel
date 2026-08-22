defmodule PowerModel.Ingestion.OSM.ApplyTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  import Ecto.Query

  alias PowerModel.Grid.{Bus, Substation, TransmissionLine}
  alias PowerModel.Ingestion.HIFLD.Substations, as: HIFLDSubstations
  alias PowerModel.Ingestion.OSM.Matcher
  alias PowerModel.Ingestion.OSM.SubstationMatch

  defp insert_yard(attrs) do
    Repo.insert!(
      struct!(
        %Substation{
          name: "UNKNOWN424242",
          hifld_id: "424242",
          voltage_levels: [],
          coordinates: %Geo.Point{coordinates: {-83.0, 40.0}, srid: 4326},
          status: "in_service"
        },
        attrs
      )
    )
  end

  defp default_bus(sub) do
    Repo.insert!(%Bus{
      bus_type: 1,
      base_kv: 138.0,
      coordinates: sub.coordinates,
      source: "substation",
      source_id: "#{sub.id}_138.0kV"
    })
  end

  defp applied_decision(sub, levels) do
    cand = %{
      type: "way",
      id: 555_001,
      name: nil,
      raw_voltage: "69000",
      lat: 40.0,
      lon: -83.0,
      levels_kv: levels
    }

    yard = %{
      id: sub.id,
      name: sub.name,
      hifld_id: sub.hifld_id,
      levels: sub.voltage_levels,
      class: :blind,
      lat: 40.0,
      lon: -83.0
    }

    {:applied, yard, cand, "distance", nil, 42.0, nil}
  end

  test "apply_decisions writes levels + provenance, records evidence, retargets the default bus" do
    sub = insert_yard(%{})
    bus = default_bus(sub)

    result =
      Matcher.apply_decisions([applied_decision(sub, [69.0])], snapshot_date: ~D[2026-08-18])

    assert %{applied: 1, held: 0, buses_retargeted: 1} = result

    reloaded = Repo.get!(Substation, sub.id)
    assert reloaded.voltage_levels == [69.0]
    assert reloaded.max_voltage_kv == 69.0
    assert reloaded.voltage_source == "osm_matched"

    match = Repo.one!(from m in SubstationMatch, where: m.substation_id == ^sub.id)
    assert match.status == "applied"
    assert match.osm_id == 555_001
    assert match.levels_kv == [69.0]

    rebus = Repo.get!(Bus, bus.id)
    assert rebus.base_kv == 69.0
    assert rebus.source_id == "#{sub.id}_69.0kV"

    [audit] = result.audit
    assert audit.old_levels == []
    assert audit.bus.old_base_kv == 138.0
  end

  test "a bus already at one of the new levels is left alone" do
    sub = insert_yard(%{hifld_id: "424243", name: "UNKNOWN424243"})
    bus = default_bus(sub)

    result =
      Matcher.apply_decisions([applied_decision(sub, [138.0, 69.0])],
        snapshot_date: ~D[2026-08-18]
      )

    assert %{applied: 1, buses_retargeted: 0} = result
    assert Repo.get!(Bus, bus.id).base_kv == 138.0
    assert Repo.get!(Substation, sub.id).voltage_levels == [138.0, 69.0]
  end

  test "augment_voltage_levels_from_lines cannot overwrite an OSM-sourced yard" do
    sub = insert_yard(%{hifld_id: "424244", name: "OSMYARD", voltage_levels: []})

    Matcher.apply_decisions([applied_decision(sub, [69.0])], snapshot_date: ~D[2026-08-18])

    # A restored-echo 138 kV line naming this yard right at its coordinates:
    # without the voltage_source guard the augmentation would merge 138 back in.
    Repo.insert!(%TransmissionLine{
      voltage_kv: 138.0,
      geometry: %Geo.LineString{coordinates: [{-83.0, 40.0}, {-82.9, 40.1}], srid: 4326},
      source: "hifld",
      source_id: "osm-guard-test-1",
      sub_1: "OSMYARD",
      sub_2: "UNKNOWN999999",
      status: "in_service"
    })

    HIFLDSubstations.augment_voltage_levels_from_lines()

    reloaded = Repo.get!(Substation, sub.id)
    assert reloaded.voltage_levels == [69.0]
    assert reloaded.voltage_source == "osm_matched"
  end
end
