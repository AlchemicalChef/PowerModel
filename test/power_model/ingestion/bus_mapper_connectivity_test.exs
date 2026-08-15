defmodule PowerModel.Ingestion.BusMapperConnectivityTest do
  @moduledoc """
  ROADMAP item 12: SUB_1/SUB_2 names as the primary endpoint key, tiered
  geometric fallback, and the post-mapping component-joining pass.
  """

  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid.{Bus, Interconnection, Substation, TransmissionLine}
  alias PowerModel.Ingestion.BusMapper

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  defp line_string(points) do
    %Geo.LineString{coordinates: points, srid: 4326}
  end

  defp substation(name, lon, lat, levels) do
    Repo.insert!(%Substation{
      name: name,
      hifld_id: "#{name}@#{lon},#{lat}",
      coordinates: point(lon, lat),
      voltage_levels: levels,
      max_voltage_kv: List.first(levels),
      min_voltage_kv: if(length(levels) > 1, do: List.last(levels)),
      status: "in_service"
    })
  end

  defp line(attrs) do
    Repo.insert!(
      struct(
        %TransmissionLine{
          source: "hifld",
          status: "in_service",
          voltage_kv: 138.0
        },
        attrs
      )
    )
  end

  defp bus_of(sub, kv) do
    Repo.get_by!(Bus,
      source: "substation",
      source_id: "#{sub.id}_#{:erlang.float_to_binary(kv * 1.0, decimals: 1)}kV"
    )
  end

  describe "SUB_1/SUB_2 names are the primary endpoint key" do
    test "a named endpoint lands on its OWN substation, not the closer one" do
      # The named yard is 6 km away; a different yard at the same voltage sits
      # 1 km away. Proximity would take the wrong one — the whole reason 45.9%
      # of endpoints ended up at the wrong substation (LIN-1).
      home = substation("KEYSTONE", -90.0, 30.0, [138.0])
      decoy = substation("OTHER YARD", -90.02, 30.0, [138.0])
      BusMapper.create_substation_buses()

      l =
        line(%{
          source_id: "l1",
          sub_1: "KEYSTONE",
          sub_2: "OTHER YARD",
          voltage_kv: 138.0,
          geometry: line_string([{-90.055, 30.0}, {-90.02, 30.0}])
        })

      BusMapper.map_transmission_line_buses()

      mapped = Repo.get!(TransmissionLine, l.id)
      assert mapped.from_bus_id == bus_of(home, 138.0).id
      assert mapped.to_bus_id == bus_of(decoy, 138.0).id
    end

    test "the endpoint lands on the substation's level closest to the line voltage" do
      sub = substation("MULTI", -90.0, 30.0, [345.0, 138.0, 69.0])
      other = substation("FAR END", -91.0, 30.0, [345.0])
      BusMapper.create_substation_buses()

      l =
        line(%{
          source_id: "l2",
          sub_1: "MULTI",
          sub_2: "FAR END",
          voltage_kv: 345.0,
          geometry: line_string([{-90.0, 30.0}, {-91.0, 30.0}])
        })

      BusMapper.map_transmission_line_buses()

      mapped = Repo.get!(TransmissionLine, l.id)
      assert mapped.from_bus_id == bus_of(sub, 345.0).id
      assert mapped.to_bus_id == bus_of(other, 345.0).id
    end

    test "sentinel-named endpoints fall through to the geometric snap" do
      near = substation("A YARD", -90.0, 30.0, [138.0])
      far = substation("B YARD", -90.05, 30.0, [138.0])
      BusMapper.create_substation_buses()

      l =
        line(%{
          source_id: "l3",
          sub_1: "NOT AVAILABLE",
          sub_2: "DEAD HEAD",
          voltage_kv: 138.0,
          geometry: line_string([{-90.0, 30.0}, {-90.05, 30.0}])
        })

      stats = BusMapper.map_transmission_line_buses()

      mapped = Repo.get!(TransmissionLine, l.id)
      assert mapped.from_bus_id == bus_of(near, 138.0).id
      assert mapped.to_bus_id == bus_of(far, 138.0).id
      assert Map.get(stats, :name_sentinel) == 2
      assert Map.get(stats, :name_matched, 0) == 0
    end

    test "a name pointing at a yard hundreds of km away is not trusted" do
      substation("MIDWAY", -80.0, 40.0, [138.0])
      local = substation("LOCAL", -90.0, 30.0, [138.0])
      substation("LOCAL 2", -90.05, 30.0, [138.0])
      BusMapper.create_substation_buses()

      l =
        line(%{
          source_id: "l4",
          sub_1: "MIDWAY",
          sub_2: "LOCAL 2",
          voltage_kv: 138.0,
          geometry: line_string([{-90.0, 30.0}, {-90.05, 30.0}])
        })

      stats = BusMapper.map_transmission_line_buses()

      mapped = Repo.get!(TransmissionLine, l.id)
      assert Map.get(stats, :name_too_far) == 1
      # Fell back to the geometric snap and took the yard actually there.
      assert mapped.from_bus_id == bus_of(local, 138.0).id
    end
  end

  describe "tiered geometric snap" do
    test "an endpoint within 2 km snaps at tier 1" do
      substation("A", -90.0, 30.0, [138.0])
      substation("B", -90.2, 30.0, [138.0])
      BusMapper.create_substation_buses()

      line(%{
        source_id: "t1",
        sub_1: "NOT AVAILABLE",
        sub_2: "NOT AVAILABLE",
        voltage_kv: 138.0,
        geometry: line_string([{-90.005, 30.0}, {-90.2, 30.0}])
      })

      stats = BusMapper.map_transmission_line_buses()
      assert Map.get(stats, :snapped_tier_1) == 2
      assert Map.get(stats, :snapped_tier_2, 0) == 0
    end

    test "an endpoint between 2 and 10 km snaps at tier 2 and is counted apart" do
      substation("A", -90.0, 30.0, [138.0])
      substation("B", -90.2, 30.0, [138.0])
      BusMapper.create_substation_buses()

      line(%{
        source_id: "t2",
        sub_1: "NOT AVAILABLE",
        sub_2: "NOT AVAILABLE",
        voltage_kv: 138.0,
        geometry: line_string([{-90.05, 30.0}, {-90.2, 30.0}])
      })

      stats = BusMapper.map_transmission_line_buses()
      assert Map.get(stats, :snapped_tier_2) == 1
      assert Map.get(stats, :snapped_tier_1) == 1
    end

    test "an endpoint beyond 10 km is left for cleanup, never force-mapped" do
      substation("A", -90.0, 30.0, [138.0])
      BusMapper.create_substation_buses()

      l =
        line(%{
          source_id: "t3",
          sub_1: "NOT AVAILABLE",
          sub_2: "NOT AVAILABLE",
          voltage_kv: 138.0,
          geometry: line_string([{-90.0, 30.0}, {-91.0, 30.0}])
        })

      stats = BusMapper.map_transmission_line_buses()

      assert Map.get(stats, :unresolved) == 1
      assert Repo.get!(TransmissionLine, l.id).to_bus_id == nil
    end

    test "the snap respects voltage class: a 345 kV endpoint never lands on 69 kV" do
      substation("LOW", -90.0, 30.0, [69.0])
      right = substation("HIGH", -90.05, 30.0, [345.0])
      substation("FAR", -90.2, 30.0, [345.0])
      BusMapper.create_substation_buses()

      l =
        line(%{
          source_id: "t4",
          sub_1: "NOT AVAILABLE",
          sub_2: "NOT AVAILABLE",
          voltage_kv: 345.0,
          geometry: line_string([{-90.0, 30.0}, {-90.2, 30.0}])
        })

      BusMapper.map_transmission_line_buses()

      assert Repo.get!(TransmissionLine, l.id).from_bus_id == bus_of(right, 345.0).id
    end

    test "a line whose endpoints resolve to one bus is skipped, not self-looped" do
      substation("ONE", -90.0, 30.0, [138.0])
      BusMapper.create_substation_buses()

      l =
        line(%{
          source_id: "t5",
          sub_1: "ONE",
          sub_2: "ONE",
          voltage_kv: 138.0,
          geometry: line_string([{-90.0, 30.0}, {-90.001, 30.0}])
        })

      stats = BusMapper.map_transmission_line_buses()

      mapped = Repo.get!(TransmissionLine, l.id)
      assert Map.get(stats, :self_loop_skipped) == 1
      assert mapped.from_bus_id == nil
      assert mapped.to_bus_id == nil
    end
  end

  describe "repair_connectivity/1" do
    setup do
      eastern = Repo.insert!(%Interconnection{name: "Eastern"})
      western = Repo.insert!(%Interconnection{name: "Western"})
      %{eastern: eastern, western: western}
    end

    defp connect(bus_a, bus_b, source_id) do
      line(%{
        source_id: source_id,
        from_bus_id: bus_a.id,
        to_bus_id: bus_b.id,
        voltage_kv: bus_a.base_kv,
        geometry: nil
      })
    end

    defp set_interconnection(buses, ic) do
      ids = Enum.map(buses, & &1.id)
      Repo.update_all(from(b in Bus, where: b.id in ^ids), set: [interconnection_id: ic.id])
    end

    test "two components at same-named yards 1 km apart are joined", %{eastern: eastern} do
      # One physical yard, surveyed twice: same name, a few hundred metres
      # apart, with the circuits split between the two records.
      a = substation("SPRINGFIELD", -90.0, 30.0, [138.0])
      b = substation("SPRINGFIELD", -90.005, 30.0, [138.0])
      a_far = substation("A FAR", -90.1, 30.0, [138.0])
      b_far = substation("B FAR", -90.2, 30.0, [138.0])
      BusMapper.create_substation_buses()

      buses = Repo.all(Bus)
      set_interconnection(buses, eastern)

      connect(bus_of(a, 138.0), bus_of(a_far, 138.0), "a")
      connect(bus_of(b, 138.0), bus_of(b_far, 138.0), "b")

      result = BusMapper.repair_connectivity()

      assert result.components_before == 2
      assert result.joined_name == 1
      assert result.components_after == 1

      joint = Repo.get_by!(TransmissionLine, source: "connectivity_repair")
      assert joint.voltage_kv == 138.0
      assert joint.length_km > 0.0
      assert joint.x_pu > 0.0
      assert joint.status == "in_service"
    end

    test "same-named yards far apart are NOT joined (LIN-1's MIDWAY)", %{eastern: eastern} do
      a = substation("MIDWAY", -90.0, 30.0, [138.0])
      b = substation("MIDWAY", -80.0, 40.0, [138.0])
      a_far = substation("A FAR", -90.1, 30.0, [138.0])
      b_far = substation("B FAR", -80.1, 40.0, [138.0])
      BusMapper.create_substation_buses()
      set_interconnection(Repo.all(Bus), eastern)

      connect(bus_of(a, 138.0), bus_of(a_far, 138.0), "a")
      connect(bus_of(b, 138.0), bus_of(b_far, 138.0), "b")

      result = BusMapper.repair_connectivity()

      assert result.joined_name == 0
      assert result.joined_proximity == 0
      assert result.components_after == result.components_before
    end

    test "adjacent buses at the same level in different components are joined", %{
      eastern: eastern
    } do
      a = substation("UNKNOWN1", -90.0, 30.0, [138.0])
      b = substation("TAP2", -90.002, 30.0, [138.0])
      a_far = substation("A FAR", -90.1, 30.0, [138.0])
      b_far = substation("B FAR", -90.2, 30.0, [138.0])
      BusMapper.create_substation_buses()
      set_interconnection(Repo.all(Bus), eastern)

      connect(bus_of(a, 138.0), bus_of(a_far, 138.0), "a")
      connect(bus_of(b, 138.0), bus_of(b_far, 138.0), "b")

      result = BusMapper.repair_connectivity()

      assert result.joined_proximity == 1
      assert result.components_after == result.components_before - 1
    end

    test "buses at DIFFERENT voltage levels are never joined", %{eastern: eastern} do
      a = substation("UNKNOWN1", -90.0, 30.0, [345.0])
      b = substation("TAP2", -90.002, 30.0, [138.0])
      a_far = substation("A FAR", -90.1, 30.0, [345.0])
      b_far = substation("B FAR", -90.2, 30.0, [138.0])
      BusMapper.create_substation_buses()
      set_interconnection(Repo.all(Bus), eastern)

      connect(bus_of(a, 345.0), bus_of(a_far, 345.0), "a")
      connect(bus_of(b, 138.0), bus_of(b_far, 138.0), "b")

      result = BusMapper.repair_connectivity()

      assert result.joined_name == 0
      assert result.joined_proximity == 0
    end

    test "a joint never crosses an interconnection seam", %{eastern: eastern, western: western} do
      a = substation("SEAM", -90.0, 30.0, [138.0])
      b = substation("SEAM", -90.002, 30.0, [138.0])
      a_far = substation("A FAR", -90.1, 30.0, [138.0])
      b_far = substation("B FAR", -90.2, 30.0, [138.0])
      BusMapper.create_substation_buses()

      set_interconnection([bus_of(a, 138.0), bus_of(a_far, 138.0)], eastern)
      set_interconnection([bus_of(b, 138.0), bus_of(b_far, 138.0)], western)

      connect(bus_of(a, 138.0), bus_of(a_far, 138.0), "a")
      connect(bus_of(b, 138.0), bus_of(b_far, 138.0), "b")

      result = BusMapper.repair_connectivity()

      assert result.joined_name == 0
      assert result.joined_proximity == 0

      assert Repo.aggregate(
               from(l in TransmissionLine, where: l.source == "connectivity_repair"),
               :count
             ) == 0
    end

    test "buses already in one component are not re-joined", %{eastern: eastern} do
      a = substation("TOGETHER", -90.0, 30.0, [138.0])
      b = substation("TOGETHER", -90.002, 30.0, [138.0])
      BusMapper.create_substation_buses()
      set_interconnection(Repo.all(Bus), eastern)

      connect(bus_of(a, 138.0), bus_of(b, 138.0), "already")

      result = BusMapper.repair_connectivity()

      assert result.joined_name == 0
      assert result.joined_proximity == 0
    end

    test "a second run is a no-op — the joints it made are now branches", %{eastern: eastern} do
      a = substation("REPEAT", -90.0, 30.0, [138.0])
      b = substation("REPEAT", -90.002, 30.0, [138.0])
      a_far = substation("A FAR", -90.1, 30.0, [138.0])
      b_far = substation("B FAR", -90.2, 30.0, [138.0])
      BusMapper.create_substation_buses()
      set_interconnection(Repo.all(Bus), eastern)

      connect(bus_of(a, 138.0), bus_of(a_far, 138.0), "a")
      connect(bus_of(b, 138.0), bus_of(b_far, 138.0), "b")

      first = BusMapper.repair_connectivity()
      assert first.joined_name + first.joined_proximity == 1

      second = BusMapper.repair_connectivity()
      assert second.joined_name == 0
      assert second.joined_proximity == 0
      assert second.components_before == first.components_after
    end

    test "the radii are configurable", %{eastern: eastern} do
      a = substation("WIDE", -90.0, 30.0, [138.0])
      b = substation("WIDE", -90.05, 30.0, [138.0])
      a_far = substation("A FAR", -90.3, 30.0, [138.0])
      b_far = substation("B FAR", -90.4, 30.0, [138.0])
      BusMapper.create_substation_buses()
      set_interconnection(Repo.all(Bus), eastern)

      connect(bus_of(a, 138.0), bus_of(a_far, 138.0), "a")
      connect(bus_of(b, 138.0), bus_of(b_far, 138.0), "b")

      # ~4.8 km apart: outside the default 5 km name radius? No — inside it,
      # so tighten the radius and watch the joint disappear.
      tight = BusMapper.repair_connectivity(name_radius_km: 1.0, proximity_km: 0.5)
      assert tight.joined_name == 0
      assert tight.joined_proximity == 0

      wide = BusMapper.repair_connectivity(name_radius_km: 10.0, proximity_km: 0.5)
      assert wide.joined_name == 1
    end
  end
end
