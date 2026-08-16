defmodule PowerModel.Ingestion.BusMapperPlacementTest do
  @moduledoc """
  DR-4: the voltage/size-aware generator placement (LIN13-B), the co-located
  weld phase (TOPO-4), the one-bus circuit split (TOPO-5), and bank sizing
  against low-side load (TOPO-6).
  """

  use PowerModel.DataCase, async: false

  @moduletag :db

  import Ecto.Query

  alias PowerModel.Grid.{Bus, Generator, Interconnection, Load, Substation, TransmissionLine}
  alias PowerModel.Grid.Transformer
  alias PowerModel.Ingestion.BusMapper

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  defp line_string(points), do: %Geo.LineString{coordinates: points, srid: 4326}

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

  defp bus_of(sub, kv) do
    Repo.get_by!(Bus,
      source: "substation",
      source_id: "#{sub.id}_#{:erlang.float_to_binary(kv * 1.0, decimals: 1)}kV"
    )
  end

  defp generator(attrs) do
    Repo.insert!(struct(%Generator{fuel_type: "NG", status: "in_service", p_max_mw: 50.0}, attrs))
  end

  defp line(attrs) do
    Repo.insert!(
      struct(
        %TransmissionLine{source: "hifld", status: "in_service", voltage_kv: 138.0},
        attrs
      )
    )
  end

  defp connect(bus_a, bus_b, source_id, rating) do
    line(%{
      source_id: source_id,
      from_bus_id: bus_a.id,
      to_bus_id: bus_b.id,
      voltage_kv: bus_a.base_kv,
      rating_a_mva: rating,
      geometry: nil
    })
  end

  defp set_interconnection(buses, ic) do
    ids = Enum.map(buses, & &1.id)
    Repo.update_all(from(b in Bus, where: b.id in ^ids), set: [interconnection_id: ic.id])
  end

  # `create_substation_buses/0` resolves the geographic box itself, so the row
  # may already be there by the time a test wants a handle on it.
  defp interconnection(name) do
    Repo.get_by(Interconnection, name: name) || Repo.insert!(%Interconnection{name: name})
  end

  describe "plant voltage floor (LIN13-B)" do
    test "the floor tracks plant size, and small units keep LIN-8 untouched" do
      assert BusMapper.plant_voltage_floor(50.0) == nil
      assert BusMapper.plant_voltage_floor(100.0) == nil
      assert BusMapper.plant_voltage_floor(100.1) == 115.0
      assert BusMapper.plant_voltage_floor(500.0) == 115.0
      assert BusMapper.plant_voltage_floor(500.1) == 230.0
      assert BusMapper.plant_voltage_floor(nil) == nil
    end
  end

  describe "generator placement" do
    test "a unit under the threshold still takes the yard's LOWEST level (LIN-8)" do
      sub = substation("SMALL", -90.0, 35.0, [230.0, 115.0, 13.8])
      gen = generator(%{p_max_mw: 60.0, coordinates: point(-90.0, 35.0)})

      BusMapper.create_substation_buses()
      BusMapper.map_generators_to_buses()

      assert Repo.get!(Generator, gen.id).bus_id == bus_of(sub, 13.8).id
    end

    test "a plant above 500 MW lands at or above 230 kV, not on the yard's floor" do
      sub = substation("BIG HYDRO", -90.0, 35.0, [500.0, 230.0, 115.0])
      gen = generator(%{p_max_mw: 900.0, coordinates: point(-90.0, 35.0)})

      BusMapper.create_substation_buses()
      BusMapper.map_generators_to_buses()

      placed = Repo.get!(Generator, gen.id).bus_id
      assert placed in [bus_of(sub, 230.0).id, bus_of(sub, 500.0).id]
      assert Repo.get!(Bus, placed).base_kv >= 230.0
    end

    test "units of one EIA plant are sized together and land on one bus" do
      sub = substation("MULTI UNIT", -90.0, 35.0, [230.0, 13.8])

      units =
        for _ <- 1..6,
            do:
              generator(%{p_max_mw: 120.0, eia_plant_id: "9001", coordinates: point(-90.0, 35.0)})

      BusMapper.create_substation_buses()
      BusMapper.map_generators_to_buses()

      buses = units |> Enum.map(&Repo.get!(Generator, &1.id).bus_id) |> Enum.uniq()

      # 6 x 120 MW is one 720 MW station, not six 120 MW machines: the floor is
      # 230 kV, and every unit lands on the same bus.
      assert [bus_id] = buses
      assert bus_id == bus_of(sub, 230.0).id
    end

    test "a nearer yard whose every level is under the floor is not a candidate" do
      low = substation("LOW YARD", -90.0, 35.0, [69.0])
      high = substation("HIGH YARD", -90.02, 35.0, [230.0])
      gen = generator(%{p_max_mw: 600.0, coordinates: point(-90.0, 35.0)})

      BusMapper.create_substation_buses()
      BusMapper.map_generators_to_buses()

      assert Repo.get!(Generator, gen.id).bus_id == bus_of(high, 230.0).id
      refute Repo.get!(Generator, gen.id).bus_id == bus_of(low, 69.0).id
    end

    test "at one site the bus that can carry the plant wins over the lowest qualifying level" do
      sub = substation("TWO LEVELS", -90.0, 35.0, [345.0, 115.0])
      far = substation("ELSEWHERE", -90.3, 35.0, [345.0])

      BusMapper.create_substation_buses()

      # The 115 kV bus qualifies on voltage but carries 50 MVA; the 345 kV bus
      # carries 900. A 400 MW plant needs 480.
      connect(bus_of(sub, 115.0), bus_of(far, 345.0), "thin", 50.0)
      connect(bus_of(sub, 345.0), bus_of(far, 345.0), "fat", 900.0)

      gen = generator(%{p_max_mw: 400.0, coordinates: point(-90.0, 35.0)})
      BusMapper.map_generators_to_buses()

      assert Repo.get!(Generator, gen.id).bus_id == bus_of(sub, 345.0).id
    end

    test "the widened search reaches a qualifying yard beyond 10 km" do
      _near = substation("NEAR LOW", -90.0, 35.0, [69.0])
      far = substation("FAR HIGH", -90.16, 35.0, [230.0])
      gen = generator(%{p_max_mw: 700.0, coordinates: point(-90.0, 35.0)})

      BusMapper.create_substation_buses()
      BusMapper.map_generators_to_buses()

      # ~14.6 km: outside the 10 km match radius, inside the 25 km widened one.
      assert Repo.get!(Generator, gen.id).bus_id == bus_of(far, 230.0).id
    end

    test "the widened search never crosses an interconnection seam" do
      eastern = interconnection("Eastern")
      western = interconnection("Western")

      near = substation("SEAM LOW", -90.0, 35.0, [69.0])
      far = substation("SEAM HIGH", -90.16, 35.0, [230.0])

      BusMapper.create_substation_buses()
      set_interconnection([bus_of(near, 69.0)], eastern)
      set_interconnection([bus_of(far, 230.0)], western)

      gen = generator(%{p_max_mw: 700.0, coordinates: point(-90.0, 35.0)})
      BusMapper.map_generators_to_buses()

      # The only qualifying bus is on the other side of the seam, so the rule
      # gives up and LIN-8's any-level placement applies.
      assert Repo.get!(Generator, gen.id).bus_id == bus_of(near, 69.0).id
    end
  end

  describe "remap_stranded_generators/1" do
    setup do
      sub = substation("STRANDED", -90.0, 35.0, [230.0, 33.0])
      other = substation("OTHER", -90.02, 35.0, [230.0])
      BusMapper.create_substation_buses()

      connect(bus_of(sub, 33.0), bus_of(other, 230.0), "thin", 60.0)
      connect(bus_of(sub, 230.0), bus_of(other, 230.0), "fat", 900.0)

      gen =
        generator(%{
          p_max_mw: 600.0,
          bus_id: bus_of(sub, 33.0).id,
          coordinates: point(-90.0, 35.0)
        })

      %{sub: sub, gen: gen}
    end

    test "a plant its bus cannot carry moves up, and the move is idempotent", %{
      sub: sub,
      gen: gen
    } do
      summary = BusMapper.remap_stranded_generators()

      assert summary.plants == 1
      assert summary.generators == 1
      assert Repo.get!(Generator, gen.id).bus_id == bus_of(sub, 230.0).id

      assert BusMapper.remap_stranded_generators() == %{
               examined: 1,
               plants: 0,
               generators: 0,
               moved_mw: 0.0
             }
    end

    test "loads are never touched, so bus->BA attribution cannot move", %{sub: sub} do
      load =
        Repo.insert!(%Load{bus_id: bus_of(sub, 33.0).id, p_mw: 40.0, status: "in_service"})

      BusMapper.remap_stranded_generators()

      assert Repo.get!(Load, load.id).bus_id == bus_of(sub, 33.0).id
    end

    test "a plant already on the best available bus is left alone" do
      sub = substation("ALREADY FINE", -80.0, 35.0, [345.0])
      BusMapper.create_substation_buses()
      other = substation("FINE PEER", -80.02, 35.0, [345.0])
      BusMapper.create_substation_buses()
      connect(bus_of(sub, 345.0), bus_of(other, 345.0), "fine", 900.0)

      gen =
        generator(%{
          p_max_mw: 600.0,
          bus_id: bus_of(sub, 345.0).id,
          coordinates: point(-80.0, 35.0)
        })

      BusMapper.remap_stranded_generators()

      assert Repo.get!(Generator, gen.id).bus_id == bus_of(sub, 345.0).id
    end
  end

  describe "one-bus circuits (TOPO-5)" do
    test "endpoints more than 1 km apart resolve to two distinct buses" do
      one = substation("ONE", -90.0, 30.0, [138.0])
      two = substation("TWO", -90.05, 30.0, [138.0])
      BusMapper.create_substation_buses()

      # Both names point at ONE; the far endpoint is 4.8 km away, on top of TWO.
      circuit =
        line(%{
          source_id: "split-me",
          sub_1: "ONE",
          sub_2: "ONE",
          voltage_kv: 138.0,
          geometry: line_string([{-90.0, 30.0}, {-90.05, 30.0}])
        })

      stats = BusMapper.map_transmission_line_buses()

      mapped = Repo.get!(TransmissionLine, circuit.id)
      assert Map.get(stats, :same_bus_split) == 1
      assert mapped.from_bus_id == bus_of(one, 138.0).id
      assert mapped.to_bus_id == bus_of(two, 138.0).id
      assert mapped.from_bus_id != mapped.to_bus_id
    end

    test "endpoints inside 1 km are still an intra-yard stub and stay unmapped" do
      substation("STUB", -90.0, 30.0, [138.0])
      BusMapper.create_substation_buses()

      circuit =
        line(%{
          source_id: "stub",
          sub_1: "STUB",
          sub_2: "STUB",
          voltage_kv: 138.0,
          geometry: line_string([{-90.0, 30.0}, {-90.003, 30.0}])
        })

      stats = BusMapper.map_transmission_line_buses()

      mapped = Repo.get!(TransmissionLine, circuit.id)
      assert Map.get(stats, :self_loop_skipped) == 1
      assert is_nil(mapped.from_bus_id)
      assert is_nil(mapped.to_bus_id)
    end

    test "with nothing at the far end, a bus is created there and the circuit maps" do
      one = substation("LONELY", -90.0, 30.0, [138.0])
      BusMapper.create_substation_buses()
      set_interconnection([bus_of(one, 138.0)], interconnection("Eastern"))

      circuit =
        line(%{
          source_id: "far-end",
          sub_1: "LONELY",
          sub_2: "LONELY",
          voltage_kv: 138.0,
          # 14.4 km: both ends still resolve to LONELY by name (25 km radius),
          # and the far end has no bus of its own inside the 10 km tier.
          geometry: line_string([{-90.0, 30.0}, {-90.15, 30.0}])
        })

      stats = BusMapper.map_transmission_line_buses()

      mapped = Repo.get!(TransmissionLine, circuit.id)
      assert Map.get(stats, :same_bus_synthetic) == 1
      assert mapped.from_bus_id == bus_of(one, 138.0).id

      created = Repo.get!(Bus, mapped.to_bus_id)
      assert created.source == "synthetic"
      assert created.source_id == "line_#{circuit.id}_to"
      assert created.base_kv == 138.0
      # It has to carry an interconnection or the weld phases will refuse it.
      assert created.interconnection_id == bus_of(one, 138.0).interconnection_id
    end
  end

  describe "co-located welds (TOPO-4)" do
    setup do
      %{eastern: interconnection("Eastern")}
    end

    test "two records of one yard already in ONE component are welded", %{eastern: eastern} do
      a = substation("YARD A", -90.0, 30.0, [138.0])
      b = substation("YARD B", -90.001, 30.0, [138.0])
      far = substation("FAR", -90.2, 30.0, [138.0])
      BusMapper.create_substation_buses()
      set_interconnection(Repo.all(Bus), eastern)

      # Both halves reach each other the long way round, so the component-join
      # rules cannot see them.
      connect(bus_of(a, 138.0), bus_of(far, 138.0), "a-far", 250.0)
      connect(bus_of(b, 138.0), bus_of(far, 138.0), "b-far", 250.0)

      summary = BusMapper.weld_colocated_buses()

      assert summary.welded == 1
      assert summary.components_before == summary.components_after

      weld = Repo.get_by!(TransmissionLine, source: "connectivity_repair")
      assert weld.voltage_kv == 138.0
      assert weld.x_pu > 0.0
      assert weld.from_bus_id != weld.to_bus_id
      assert String.starts_with?(weld.source_id, "repair_weld_")
    end

    test "a second run adds nothing", %{eastern: eastern} do
      substation("REPEAT A", -90.0, 30.0, [138.0])
      substation("REPEAT B", -90.001, 30.0, [138.0])
      BusMapper.create_substation_buses()
      set_interconnection(Repo.all(Bus), eastern)

      assert BusMapper.weld_colocated_buses().welded == 1
      assert BusMapper.weld_colocated_buses().welded == 0
    end

    test "pairs beyond 250 m, at other levels, or already joined are left alone", %{
      eastern: eastern
    } do
      a = substation("NEAR", -90.0, 30.0, [138.0])
      # 3.1 km east: outside the 250 m weld radius, and far enough from the
      # other two that it cannot pair with them either.
      _distant = substation("3 KM AWAY", -90.031, 30.0, [138.0])
      _other_level = substation("OTHER LEVEL", -90.0005, 30.0, [345.0])
      already = substation("ALREADY", -90.0008, 30.0, [138.0])
      BusMapper.create_substation_buses()
      set_interconnection(Repo.all(Bus), eastern)

      connect(bus_of(a, 138.0), bus_of(already, 138.0), "direct", 250.0)

      assert BusMapper.weld_colocated_buses().welded == 0
    end

    test "a weld never crosses an interconnection seam", %{eastern: eastern} do
      western = interconnection("Western")
      a = substation("SEAM A", -90.0, 30.0, [138.0])
      b = substation("SEAM B", -90.001, 30.0, [138.0])
      BusMapper.create_substation_buses()
      set_interconnection([bus_of(a, 138.0)], eastern)
      set_interconnection([bus_of(b, 138.0)], western)

      assert BusMapper.weld_colocated_buses().welded == 0
    end
  end

  describe "bank sizing against low-side load (TOPO-6)" do
    test "a bank carrying more than its class unit is sized up in whole units" do
      sub = substation("BIG LOAD", -90.0, 35.0, [115.0, 33.0])
      BusMapper.create_substation_buses()
      BusMapper.create_substation_transformers()

      bank = Repo.one!(from(t in Transformer))
      # 115 kV high side: the class's standard unit is 100 MVA.
      assert bank.rated_mva == 100.0

      Repo.insert!(%Load{bus_id: bus_of(sub, 33.0).id, p_mw: 214.5, status: "in_service"})

      assert %{resized: 1} = BusMapper.resize_transformers_to_through_load()

      resized = Repo.reload!(bank)
      # 214.5 / 0.8 = 268.1 -> three 100 MVA banks.
      assert resized.rated_mva == 300.0
      # LIN-3 rebase: three banks in parallel are a third of one bank's x_pu.
      assert_in_delta resized.x_pu, 0.1 * 100.0 / 300.0, 1.0e-9
    end

    test "the rating follows the load back down when the load moves away" do
      sub = substation("MOVING LOAD", -90.0, 35.0, [115.0, 33.0])
      BusMapper.create_substation_buses()
      BusMapper.create_substation_transformers()

      load = Repo.insert!(%Load{bus_id: bus_of(sub, 33.0).id, p_mw: 500.0, status: "in_service"})
      BusMapper.resize_transformers_to_through_load()
      assert Repo.one!(from(t in Transformer)).rated_mva == 700.0

      Repo.delete!(load)
      assert %{resized: 1} = BusMapper.resize_transformers_to_through_load()
      assert Repo.one!(from(t in Transformer)).rated_mva == 100.0
    end

    test "a yard with no load keeps the class standard and the pass is a no-op" do
      substation("NO LOAD", -90.0, 35.0, [345.0, 138.0])
      BusMapper.create_substation_buses()
      BusMapper.create_substation_transformers()

      assert Repo.one!(from(t in Transformer)).rated_mva == 600.0
      assert %{resized: 0} = BusMapper.resize_transformers_to_through_load()
    end
  end
end
