defmodule PowerModel.Ingestion.InternationalConnectionsTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias PowerModel.Grid.{Bus, TransmissionLine}
  alias PowerModel.Ingestion.InternationalConnections

  test "the HQ Phase II HVDC link exists exactly once, terminating at Sandy Pond (PLT-10)" do
    {:ok, _} = InternationalConnections.run()

    sandy_pond_lines =
      Repo.all(
        from tl in TransmissionLine,
          where: tl.source == "international" and like(tl.source_id, "%sandy_pond%")
      )

    phase_ii_lines =
      Repo.all(
        from tl in TransmissionLine,
          where: tl.source == "international" and like(tl.source_id, "%hq_phase_ii%")
      )

    # One physical link -> one line; the old data listed the same Phase II
    # link twice (once with its US terminal misplaced in upstate NY).
    assert length(phase_ii_lines) == 1
    assert sandy_pond_lines == phase_ii_lines

    [line] = phase_ii_lines

    us_bus = Repo.get!(Bus, line.from_bus_id)
    %Geo.Point{coordinates: {lon, lat}} = us_bus.coordinates

    # Sandy Pond converter station, Ayer MA — not upstate New York.
    assert_in_delta lon, -71.58, 0.01
    assert_in_delta lat, 42.56, 0.01
  end

  test "run is idempotent" do
    {:ok, n} = InternationalConnections.run()
    {:ok, ^n} = InternationalConnections.run()

    line_count =
      Repo.aggregate(from(tl in TransmissionLine, where: tl.source == "international"), :count)

    assert line_count == n
  end
end
