defmodule PowerModel.Ingestion.CleanupMultiLevelTest do
  @moduledoc """
  Cleanup's wide-radius fallbacks against the multi-level bus population
  (LIN-5). Every level of a substation now has its own bus at the SAME
  coordinate, so a search that ranks candidates by distance alone can no
  longer tell them apart — the tie has to be broken on voltage.
  """

  use PowerModel.DataCase, async: false

  @moduletag :db

  import Ecto.Query

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
    test "a generator takes the lowest ADEQUATE level of the nearest yard" do
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
      # on a transmission bus, and at 500 MW the LIN13-B floor is 115 kV, which
      # 138 clears — so the yard's lowest level still wins.
      assert Repo.get!(Generator, gen.id).bus_id == bus_of(sub, "138.0").id
    end
  end

  describe "cleanup's wide-radius generator remap (LIN13-B)" do
    test "a GW-scale plant on a synthetic bus is not dragged down to a distant low level" do
      # Cleanup's search radius is 100 km and its old tie-break took the lowest
      # level of whatever yard it found — which would undo the placement rule
      # for exactly the plants that rule exists for.
      low = insert_substation("LOW YARD", -90.4, 35.0, [69.0])
      high = insert_substation("EHV YARD", -90.6, 35.0, [500.0, 230.0])
      BusMapper.create_substation_buses()

      synthetic =
        Repo.insert!(%Bus{
          bus_type: 2,
          base_kv: 13.8,
          vm_pu: 1.0,
          va_rad: 0.0,
          coordinates: point(-90.0, 35.0),
          source: "synthetic",
          source_id: "gen_test",
          interconnection_id: Repo.one!(from(b in Bus, limit: 1)).interconnection_id
        })

      gen =
        Repo.insert!(%Generator{
          p_max_mw: 1200.0,
          fuel_type: "HYC",
          status: "in_service",
          bus_id: synthetic.id,
          coordinates: point(-90.0, 35.0)
        })

      Cleanup.remap_generators()

      placed = Repo.get!(Bus, Repo.get!(Generator, gen.id).bus_id)
      assert placed.base_kv >= 230.0
      assert placed.id in [bus_of(high, "230.0").id, bus_of(high, "500.0").id]
      refute placed.id == bus_of(low, "69.0").id
    end
  end
end
