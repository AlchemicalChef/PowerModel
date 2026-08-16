defmodule Mix.Tasks.Grid.Census.LoadPlacementTest do
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias Mix.Tasks.Grid.Census.LoadPlacement

  # The census is scored on a network passed in, so the sections can be
  # exercised without a snapshot or a demand hour.
  defp bus(id, base_kv, substation_id) do
    %{id: id, base_kv: base_kv, source: "substation", source_id: "#{substation_id}_#{base_kv}kV"}
  end

  defp line(from, to, mva),
    do: %{id: from * 1000 + to, from_bus_id: from, to_bus_id: to, rating_a_mva: mva}

  defp bank(from, to, mva),
    do: %{id: from * 1000 + to, from_bus_id: from, to_bus_id: to, rated_mva: mva}

  defp load(bus_id, mw), do: %{bus_id: bus_id, p_mw: mw}

  test "a degree-0 bus with load is unservable" do
    network = %{
      buses: [bus(1, 138.0, 1), bus(2, 138.0, 2)],
      lines: [],
      transformers: [],
      loads: [load(1, 40.0), load(2, 0.0)]
    }

    report = LoadPlacement.summarize(network)

    # Both buses have no branch; only the one actually holding MW is a defect.
    assert report.unservable.count == 1
    assert report.unservable.mw == 40.0
  end

  test "a radial above the limit is counted once, over its branch and over its cap" do
    # A chain 1 - 2 - 3: the ends are radial, the middle is not.
    network = %{
      buses: [bus(1, 138.0, 1), bus(2, 138.0, 2), bus(3, 138.0, 3)],
      lines: [line(1, 2, 250.0), line(2, 3, 250.0)],
      transformers: [],
      loads: [load(1, 300.0), load(2, 10.0), load(3, 5.0)]
    }

    report = LoadPlacement.summarize(network)

    assert report.radial_over_limit.count == 1
    assert report.over_branch_rating.count == 1
    assert report.over_capability.count == 1
    assert [row] = report.over_capability.rows
    assert row.bus_id == 1
    assert_in_delta row.cap_mw, 200.0, 0.01
    assert_in_delta report.deg1_share, 305.0 / 315.0, 1.0e-4
  end

  test "capability ignores an inflated stored bank rating" do
    # A 138 kV bank is 200 MVA by class whatever the row says, so 300 MW on the
    # low side is over the cap even though the stored rating is 4000 MVA.
    network = %{
      buses: [bus(1, 138.0, 1), bus(2, 69.0, 1), bus(3, 138.0, 2)],
      lines: [line(1, 3, 600.0)],
      transformers: [bank(1, 2, 4000.0)],
      loads: [load(2, 300.0)]
    }

    report = LoadPlacement.summarize(network)

    assert report.over_capability.count == 1
    assert report.transformer_fed.count == 1
    assert [row] = report.transformer_fed.rows
    assert_in_delta row.bank_mva, 200.0, 0.01
  end

  test "a yard carrying load on two levels is reported with the duplicate MW" do
    network = %{
      buses: [bus(1, 115.0, 74_234), bus(2, 33.0, 74_234), bus(3, 115.0, 9)],
      lines: [line(1, 3, 600.0)],
      transformers: [bank(1, 2, 300.0)],
      loads: [load(1, 214.45), load(2, 214.45)]
    }

    report = LoadPlacement.summarize(network)

    assert report.split_yards.count == 1
    assert [yard] = report.split_yards.rows
    assert yard.yard_id == 74_234
    assert yard.levels == 2
    assert_in_delta yard.duplicate_mw, 214.45, 0.1
    assert report.below_load_floor.count == 1
    assert_in_delta report.below_load_floor.mw, 214.45, 0.1
  end

  test "report/1 names its graph and defaults to the simulated one" do
    report = LoadPlacement.report([])

    assert report.census == "load_placement"
    assert report.graph == "main-island"
    assert report.graph_description =~ "get_grid_snapshot"
  end

  test "the census family front door dispatches load_placement" do
    report = Mix.Tasks.Grid.Census.report("load_placement", graph: "db")

    assert report.census == "load_placement"
    assert report.graph == "db"
  end
end
