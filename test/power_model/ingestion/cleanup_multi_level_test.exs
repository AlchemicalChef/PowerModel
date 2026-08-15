defmodule PowerModel.Ingestion.CleanupMultiLevelTest do
  @moduledoc """
  Cleanup's wide-radius fallbacks against the multi-level bus population
  (LIN-5). Every level of a substation now has its own bus at the SAME
  coordinate, so a search that ranks candidates by distance alone can no
  longer tell them apart — the tie has to be broken on voltage.
  """

  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid.{Bus, Generator, Substation, TransmissionLine}
  alias PowerModel.Ingestion.{BusMapper, Cleanup}

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  defp line_string(from, to), do: %Geo.LineString{coordinates: [from, to], srid: 4326}

  defp insert_substation(name, lon, lat, levels) do
    Repo.insert!(%Substation{
      name: name,
      voltage_levels: levels,
      max_voltage_kv: List.first(levels),
      min_voltage_kv: List.last(levels),
      coordinates: point(lon, lat)
    })
  end

  defp bus_of(sub, kv) do
    Repo.get_by!(Bus, source: "substation", source_id: "#{sub.id}_#{kv}kV")
  end

  describe "remap_unmapped_lines/0 with a bus at every level" do
    test "a 230 kV line lands on the 230 kV bus at each end, not the yard's extremes" do
      west = insert_substation("WEST", -90.0, 35.0, [500.0, 345.0, 230.0, 115.0])
      east = insert_substation("EAST", -89.5, 35.0, [500.0, 230.0, 69.0])

      BusMapper.create_substation_buses()

      # Endpoints ~8 km outside the 5 km snap window, so only Cleanup's
      # 50 km / +/-20% pass can resolve them.
      line =
        Repo.insert!(%TransmissionLine{
          voltage_kv: 230.0,
          status: "in_service",
          geometry: line_string({-89.91, 35.0}, {-89.59, 35.0})
        })

      Cleanup.remap_unmapped_lines()

      reloaded = Repo.get!(TransmissionLine, line.id)
      assert reloaded.from_bus_id == bus_of(west, "230.0").id
      assert reloaded.to_bus_id == bus_of(east, "230.0").id
    end

    test "the level nearest the line's voltage wins inside the +/-20% window" do
      # 230 and 190 are both inside a 230 kV line's +/-20% window and sit at
      # one coordinate; only the voltage tiebreak separates them.
      sub = insert_substation("WEST", -90.0, 35.0, [230.0, 190.0])
      insert_substation("EAST", -89.5, 35.0, [230.0])

      BusMapper.create_substation_buses()

      line =
        Repo.insert!(%TransmissionLine{
          voltage_kv: 230.0,
          status: "in_service",
          geometry: line_string({-89.91, 35.0}, {-89.59, 35.0})
        })

      Cleanup.remap_unmapped_lines()

      reloaded = Repo.get!(TransmissionLine, line.id)
      assert reloaded.from_bus_id == bus_of(sub, "230.0").id
    end

    test "a line whose voltage has no level anywhere in range stays unmapped" do
      insert_substation("WEST", -90.0, 35.0, [500.0])
      insert_substation("EAST", -89.5, 35.0, [500.0])

      BusMapper.create_substation_buses()

      line =
        Repo.insert!(%TransmissionLine{
          voltage_kv: 69.0,
          status: "in_service",
          geometry: line_string({-89.91, 35.0}, {-89.59, 35.0})
        })

      Cleanup.remap_unmapped_lines()

      reloaded = Repo.get!(TransmissionLine, line.id)
      assert is_nil(reloaded.from_bus_id)
      assert is_nil(reloaded.to_bus_id)
    end
  end

  describe "generator placement across levels" do
    test "a generator takes the lowest level of the nearest yard, deterministically" do
      sub = insert_substation("PLANT SWITCHYARD", -90.0, 35.0, [500.0, 345.0, 138.0])

      gen =
        Repo.insert!(%Generator{
          p_max_mw: 500.0,
          fuel_type: "NG",
          status: "in_service",
          coordinates: point(-90.001, 35.0)
        })

      BusMapper.run()

      # LIN-8 (no GSU model) is unchanged: the generator still lands directly
      # on a transmission bus. What this pins is WHICH one, now that a yard
      # offers several buses at one coordinate.
      assert Repo.get!(Generator, gen.id).bus_id == bus_of(sub, "138.0").id
    end
  end
end
