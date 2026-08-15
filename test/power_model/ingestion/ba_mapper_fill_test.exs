defmodule PowerModel.Ingestion.BAMapperFillTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid.{BalancingAuthority, Bus, TransmissionLine}
  alias PowerModel.Ingestion.BAMapper

  defp point(lon, lat), do: %Geo.Point{coordinates: {lon, lat}, srid: 4326}

  defp bus(extra \\ []) do
    Repo.insert!(struct!(%Bus{bus_type: 1, base_kv: 138.0}, extra))
  end

  defp connect(a, b) do
    Repo.insert!(%TransmissionLine{
      voltage_kv: 138.0,
      from_bus_id: a.id,
      to_bus_id: b.id,
      x_pu: 0.1,
      status: "in_service"
    })
  end

  # assign_buses/2 with empty plant data runs only the nearest-neighbor and
  # topology fill passes, which is what these tests target. Target buses get
  # no coordinates so the nearest-neighbor pass cannot touch them.
  defp run_fills, do: BAMapper.assign_buses(%{}, %{})

  describe "topology fill (DAT-4)" do
    test "takes the majority BA of all neighbors, not max(ba_id)" do
      ba_a = Repo.insert!(%BalancingAuthority{code: "AAA", name: "A"})
      # Inserted later -> higher id: the old max(ba_id) pick would choose it.
      ba_b = Repo.insert!(%BalancingAuthority{code: "ZZZ", name: "Z"})
      assert ba_b.id > ba_a.id

      target = bus()
      n1 = bus(balancing_authority_id: ba_a.id)
      n2 = bus(balancing_authority_id: ba_a.id)
      n3 = bus(balancing_authority_id: ba_b.id)

      connect(target, n1)
      connect(n2, target)
      connect(target, n3)

      {_direct, _filled, propagated} = run_fills()

      assert propagated == 1
      assert Repo.get!(Bus, target.id).balancing_authority_id == ba_a.id
    end

    test "ties break deterministically on the smallest BA code" do
      ba_late = Repo.insert!(%BalancingAuthority{code: "BBB", name: "B"})
      # Higher id but alphabetically-smaller code: code must win the tiebreak.
      ba_small_code = Repo.insert!(%BalancingAuthority{code: "AAB", name: "A"})
      assert ba_small_code.id > ba_late.id

      target = bus()
      n1 = bus(balancing_authority_id: ba_late.id)
      n2 = bus(balancing_authority_id: ba_small_code.id)

      connect(target, n1)
      connect(target, n2)

      run_fills()

      assert Repo.get!(Bus, target.id).balancing_authority_id == ba_small_code.id
    end

    test "propagates along chains of unassigned buses to a fixpoint" do
      ba = Repo.insert!(%BalancingAuthority{code: "CISO", name: "CISO"})

      seeded = bus(balancing_authority_id: ba.id)
      middle = bus()
      far = bus()

      connect(seeded, middle)
      connect(middle, far)

      {_direct, _filled, propagated} = run_fills()

      assert propagated == 2
      assert Repo.get!(Bus, middle.id).balancing_authority_id == ba.id
      assert Repo.get!(Bus, far.id).balancing_authority_id == ba.id
    end
  end

  describe "nearest-neighbor fill (DAT-10)" do
    test "reports zero when no donor exists and writes nothing" do
      # A coordinate-bearing bus with no BA anywhere in the system: the old
      # UPDATE wrote NULL over NULL and counted it as an assignment.
      lonely = bus(coordinates: point(-100.0, 40.0))

      {_direct, filled, _propagated} = run_fills()

      assert filled == 0
      assert Repo.get!(Bus, lonely.id).balancing_authority_id == nil
    end

    test "assigns from the nearest donor and counts only real assignments" do
      ba = Repo.insert!(%BalancingAuthority{code: "MISO", name: "MISO"})

      _donor = bus(balancing_authority_id: ba.id, coordinates: point(-90.0, 40.0))
      receiver = bus(coordinates: point(-90.1, 40.0))

      {_direct, filled, _propagated} = run_fills()

      assert filled == 1
      assert Repo.get!(Bus, receiver.id).balancing_authority_id == ba.id
    end
  end
end
