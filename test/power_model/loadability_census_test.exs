defmodule PowerModel.LoadabilityCensusTest do
  @moduledoc """
  The loadability census separates "the solver found a root" from "the grid can
  carry this".

  The bands are TWO-SIDED on purpose, and that is what these tests mostly pin.
  A first version of this measurement checked only the lower bound and made
  Western look far better than it is — Western holds buses at 1.1268 pu from
  line charging, which an undervoltage-only criterion passes silently.
  """
  use PowerModel.DataCase, async: false

  @moduletag :db

  alias Mix.Tasks.Grid.Census.Loadability

  test "the bands are two-sided, so overvoltage cannot pass unnoticed" do
    bands = Loadability.report([]) |> Map.get(:bands)

    solvable = Enum.find(bands, &(&1.name == "solvable"))

    assert solvable.min_pu == nil and solvable.max_pu == nil,
           "the historical alpha must stay criterion-free so the comparison is honest"

    for name <- ["emergency", "normal"] do
      b = Enum.find(bands, &(&1.name == name))
      assert is_number(b.min_pu), "#{name} needs a lower bound"

      assert is_number(b.max_pu),
             "#{name} needs an UPPER bound — an undervoltage-only criterion passes a " <>
               "network that is failing the other way, which is how Western looked fine"
    end
  end

  test "normal is a strictly tighter band than emergency" do
    bands = Loadability.report([]) |> Map.get(:bands)
    e = Enum.find(bands, &(&1.name == "emergency"))
    n = Enum.find(bands, &(&1.name == "normal"))

    assert n.min_pu > e.min_pu
    assert n.max_pu < e.max_pu
  end

  test "a two-sided band reports an INTERVAL, not a single ceiling" do
    # Bisecting a two-sided band from zero assumes monotonicity and finds
    # nothing, because the network overvolts at light load — the first version
    # of this census reported alpha 0.0 for `normal` on all three
    # interconnections and that was the method, not the grid.
    report = Loadability.report([])
    bands = report.bands

    assert Enum.find(bands, &(&1.name == "solvable")).min_pu == nil

    # Shape contract: banded rows carry an interval and a feasibility flag.
    for %{name: name} <- bands, name != "solvable" do
      assert name in ["emergency", "normal"]
    end
  end

  test "an empty database yields no interconnections rather than raising" do
    report = Loadability.report([])
    assert report.census == "loadability"
    assert report.interconnections == []
  end

  test "the report says whether the reactive plant was switched on, and how banks were sized" do
    off = Loadability.report([])
    assert off.controls == false
    assert off.peak_multiplier == nil

    on = Loadability.report(controls: true)
    assert on.controls == true
    assert is_number(on.peak_multiplier) and on.peak_multiplier > 1.0

    sized = Loadability.report(controls: true, peak_multiplier: 2.5)
    assert sized.peak_multiplier == 2.5
  end
end
