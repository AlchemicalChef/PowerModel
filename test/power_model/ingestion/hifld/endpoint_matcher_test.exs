defmodule PowerModel.Ingestion.HIFLD.EndpointMatcherTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid.Substation
  alias PowerModel.Ingestion.HIFLD.EndpointMatcher

  defp substation(name, lon, lat) do
    Repo.insert!(%Substation{
      name: name,
      hifld_id: "#{name}-#{lon}-#{lat}",
      coordinates: %Geo.Point{coordinates: {lon, lat}, srid: 4326},
      status: "in_service"
    })
  end

  describe "build_index/0" do
    test "indexes identifying names, normalized, and leaves sentinels out" do
      substation("Midway", -90.0, 30.0)
      substation("  keystone  ", -80.0, 40.0)
      substation("DEAD HEAD", -70.0, 45.0)
      substation("NOT AVAILABLE", -70.1, 45.1)

      index = EndpointMatcher.build_index()

      assert Map.has_key?(index, "MIDWAY")
      assert Map.has_key?(index, "KEYSTONE")
      refute Map.has_key?(index, "DEAD HEAD")
      refute Map.has_key?(index, "NOT AVAILABLE")
    end

    test "HIFLD's suffixed ids are indexed — they are per-yard keys" do
      substation("UNKNOWN107655", -90.0, 30.0)
      substation("TAP176040", -91.0, 31.0)

      index = EndpointMatcher.build_index()

      assert Map.has_key?(index, "UNKNOWN107655")
      assert Map.has_key?(index, "TAP176040")
    end
  end

  describe "resolve/4" do
    setup do
      near = substation("MIDWAY", -90.0, 30.0)
      far = substation("MIDWAY", -80.0, 40.0)
      substation("KEYSTONE", -75.0, 41.0)

      %{index: EndpointMatcher.build_index(), near: near, far: far}
    end

    test "an exact name within radius resolves to that substation", %{index: index, near: near} do
      assert {:ok, id, distance} = EndpointMatcher.resolve(index, "MIDWAY", {-90.01, 30.0}, 25.0)
      assert id == near.id
      assert distance < 2.0
    end

    test "names are matched case- and whitespace-insensitively", %{index: index, near: near} do
      assert {:ok, id, _} = EndpointMatcher.resolve(index, "  midway ", {-90.0, 30.0}, 25.0)
      assert id == near.id
    end

    test "the NEAREST same-name substation wins (LIN-1 disambiguation)", %{
      index: index,
      near: near,
      far: far
    } do
      assert {:ok, near_id, _} = EndpointMatcher.resolve(index, "MIDWAY", {-90.0, 30.0}, 25.0)
      assert near_id == near.id

      assert {:ok, far_id, _} = EndpointMatcher.resolve(index, "MIDWAY", {-80.02, 40.0}, 25.0)
      assert far_id == far.id
    end

    test "a name whose nearest yard is beyond the radius is rejected, not trusted", %{
      index: index
    } do
      assert {:too_far, _id, distance} =
               EndpointMatcher.resolve(index, "MIDWAY", {-85.0, 35.0}, 25.0)

      assert distance > 25.0
    end

    test "sentinel names never resolve", %{index: index} do
      assert EndpointMatcher.resolve(index, "NOT AVAILABLE", {-90.0, 30.0}, 25.0) == :no_name
      assert EndpointMatcher.resolve(index, "DEAD HEAD", {-90.0, 30.0}, 25.0) == :no_name
      assert EndpointMatcher.resolve(index, nil, {-90.0, 30.0}, 25.0) == :no_name
      assert EndpointMatcher.resolve(index, "  ", {-90.0, 30.0}, 25.0) == :no_name
    end

    test "a real name absent from the substation layer is distinguishable", %{index: index} do
      assert EndpointMatcher.resolve(index, "NO SUCH YARD", {-90.0, 30.0}, 25.0) == :no_match
    end
  end

  describe "haversine_km/4" do
    test "a degree of latitude is about 111 km" do
      assert_in_delta EndpointMatcher.haversine_km(30.0, -90.0, 31.0, -90.0), 111.2, 0.5
    end

    test "identical points are zero apart" do
      assert EndpointMatcher.haversine_km(30.0, -90.0, 30.0, -90.0) == 0.0
    end
  end
end
