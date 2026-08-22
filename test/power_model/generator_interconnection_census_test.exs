defmodule PowerModel.GeneratorInterconnectionCensusTest do
  @moduledoc """
  The generation-side mirror of the load-placement census.

  Two design decisions are pinned here because both were WRONG in the obvious
  version and only measurement against the reference corpus showed it:

    * the metric is POI voltage, not degree — a generator bus with no line of
      its own is NORMAL (22.4% of `case_ACTIVSg2000`'s buses are, because it
      models machines behind an explicit step-up);
    * the comparison carries a class tolerance, because 220 kV and 230 kV are
      the same class in different utilities and a raw comparison flags the
      whole of southern California.
  """
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias Mix.Tasks.Grid.Census.GeneratorInterconnection, as: Census
  alias PowerModel.Grid.{Bus, Generator, Interconnection, Transformer, TransmissionLine}
  alias PowerModel.Repo

  defp bus(ic, kv, tag, coords \\ {-97.0, 31.0}) do
    {lon, lat} = coords

    Repo.insert!(%Bus{
      base_kv: kv,
      bus_type: 1,
      source: "substation",
      source_id: "#{tag}_#{kv}kV",
      interconnection_id: ic.id,
      coordinates: %Geo.Point{coordinates: {lon, lat}, srid: 4326}
    })
  end

  defp line(a, b, kv) do
    Repo.insert!(%TransmissionLine{
      from_bus_id: a.id,
      to_bus_id: b.id,
      voltage_kv: kv,
      r_pu: 0.01,
      x_pu: 0.05,
      b_pu: 0.001,
      rating_a_mva: 200.0,
      status: "in_service",
      source: "test"
    })
  end

  defp gen(bus, mw) do
    Repo.insert!(%Generator{
      bus_id: bus.id,
      generator_id: "g#{bus.id}",
      fuel_type: "natural_gas",
      p_max_mw: mw,
      status: "in_service"
    })
  end

  setup do
    {:ok, ic} = Repo.insert(%Interconnection{name: "CensusTest"})
    {:ok, ic: ic}
  end

  defp section(ic) do
    Census.report(interconnection: ic.name).interconnections |> hd()
  end

  test "a big plant escaping only through sub-transmission is flagged", %{ic: ic} do
    # The measured ERCOT shape: a 345 kV switchyard with no 345 kV lines,
    # reachable only by a transformer down to 69 kV.
    yard = bus(ic, 345.0, "strand")
    low = bus(ic, 69.0, "strand")
    other = bus(ic, 69.0, "neighbour")

    Repo.insert!(%Transformer{
      from_bus_id: yard.id,
      to_bus_id: low.id,
      rated_mva: 600.0,
      r_pu: 0.001,
      x_pu: 0.0167,
      tap_ratio: 1.0,
      status: "in_service"
    })

    line(low, other, 69.0)
    gen(yard, 525.0)

    s = section(ic)

    assert s.below_floor_count == 1
    row = hd(s.below_floor)
    assert row.bus == yard.id
    assert row.escape_kv == 69.0
    assert row.floor_kv > 69.0
    assert s.below_floor_mw == 525.0
  end

  test "the same plant on a proper EHV yard is not flagged", %{ic: ic} do
    yard = bus(ic, 345.0, "good")
    far = bus(ic, 345.0, "far")
    line(yard, far, 345.0)
    gen(yard, 525.0)

    assert section(ic).below_floor_count == 0
  end

  test "a generator bus with no line of its own is NOT flagged when its step-up reaches EHV",
       %{ic: ic} do
    # 22.4% of the reference case looks exactly like this. Flagging it would
    # make the census fire on normal modelling.
    terminal = bus(ic, 18.0, "term")
    high = bus(ic, 345.0, "high")
    far = bus(ic, 345.0, "farhigh")

    Repo.insert!(%Transformer{
      from_bus_id: terminal.id,
      to_bus_id: high.id,
      rated_mva: 700.0,
      r_pu: 0.001,
      x_pu: 0.02,
      tap_ratio: 1.0,
      status: "in_service"
    })

    line(high, far, 345.0)
    gen(terminal, 600.0)

    s = section(ic)
    assert s.below_floor_count == 0
    assert s.unconnected_count == 0
  end

  test "220 kV is not flagged against a 230 kV floor", %{ic: ic} do
    # SCE runs 220 kV where PG&E runs 230. Without the class tolerance this
    # case flags 1.3 GW of real Western generation as stranded.
    yard = bus(ic, 220.0, "socal")
    far = bus(ic, 220.0, "socalfar")
    line(yard, far, 220.0)
    gen(yard, 1500.0)

    assert section(ic).below_floor_count == 0
  end

  test "115 kV IS flagged against a 138 kV floor — a real class gap", %{ic: ic} do
    yard = bus(ic, 115.0, "midsize")
    far = bus(ic, 115.0, "midsizefar")
    line(yard, far, 115.0)
    gen(yard, 400.0)

    assert section(ic).below_floor_count == 1
  end

  test "generation on a bus with no branch at all is its own section", %{ic: ic} do
    orphan = bus(ic, 69.0, "orphan")
    gen(orphan, 300.0)

    s = section(ic)
    assert s.unconnected_count == 1
    assert s.unconnected_mw == 300.0
    # It cannot also be a POI violation: it has no POI to compare.
    assert s.below_floor_count == 0
  end

  test "a flagged bus reports how far the nearest adequate bus is", %{ic: ic} do
    # The reach column is what makes the section a work list rather than a
    # tally: a plant whose floor is 30 km away is a missing circuit somebody
    # can go and find.
    yard = bus(ic, 69.0, "reach", {-97.0, 31.0})
    near = bus(ic, 69.0, "reachnear", {-97.0, 31.0})
    line(yard, near, 69.0)

    # ~0.3 degrees of longitude at 31N is roughly 29 km.
    high = bus(ic, 345.0, "reachhigh", {-96.7, 31.0})
    highfar = bus(ic, 345.0, "reachhighfar", {-96.7, 31.05})
    line(high, highfar, 345.0)

    gen(yard, 400.0)

    row = section(ic).below_floor |> hd()

    assert row.reach_bus in [high.id, highfar.id]
    assert row.reach_kv == 345.0
    assert row.reach_km > 20.0 and row.reach_km < 40.0
  end

  test "a plant below the smallest reference band is unscored, not passed", %{ic: ic} do
    yard = bus(ic, 69.0, "tiny")
    far = bus(ic, 69.0, "tinyfar")
    line(yard, far, 69.0)
    gen(yard, 10.0)

    # 10 MW is under the 25 MW band, so the corpus has no opinion and the
    # census must not invent one.
    assert PowerModel.Reference.poi_floor_kv(10) == nil
    assert section(ic).below_floor_count == 0
  end
end
