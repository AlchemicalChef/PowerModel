defmodule PowerModel.Engine.CategorizeLineFlowsTest do
  @moduledoc """
  The map-facing flow classifier must surface both category jumps and
  within-category load shifting (delta vs pre-failure base loading).
  """
  use ExUnit.Case, async: true

  alias PowerModel.Engine.SimulationServer

  defp flow(id, loading_pct) do
    {{:line, id}, %{from_bus_id: 1, to_bus_id: 2, p_flow_mw: 0.0, loading_pct: loading_pct}}
  end

  defp categorize(flows, base_cats, base_loading) do
    SimulationServer.categorize_line_flows(Map.new(flows), base_cats, base_loading)
  end

  test "category jump into rerouted band is reported" do
    # base 20% (cat 0) -> 40% (cat 1)
    {ol, st, rt} = categorize([flow(1, 40.0)], %{}, %{{:line, 1} => 20.0})
    assert {ol, st, rt} == {[], [], [1]}
  end

  test "load shift within the same category is reported (the load-shifting fix)" do
    # base 35% -> 55%: cat 1 both, previously invisible; +20 pts must show
    {_, _, rt} = categorize([flow(1, 55.0)], %{{:line, 1} => 1}, %{{:line, 1} => 35.0})
    assert rt == [1]

    # base 78% -> 92%: cat 2 both, +14 pts -> stressed
    {_, st, _} = categorize([flow(2, 92.0)], %{{:line, 2} => 2}, %{{:line, 2} => 78.0})
    assert st == [2]
  end

  test "small drift within a category stays hidden" do
    {ol, st, rt} = categorize([flow(1, 38.0)], %{{:line, 1} => 1}, %{{:line, 1} => 35.0})
    assert {ol, st, rt} == {[], [], []}
  end

  test "lightly loaded lines stay hidden even with a big relative shift" do
    # 5% -> 18%: +13 pts but below the 20% visibility floor
    {ol, st, rt} = categorize([flow(1, 18.0)], %{}, %{{:line, 1} => 5.0})
    assert {ol, st, rt} == {[], [], []}
  end

  test "new overload is reported as overloaded" do
    {ol, _, _} = categorize([flow(1, 110.0)], %{{:line, 1} => 2}, %{{:line, 1} => 80.0})
    assert ol == [1]
  end

  test "pre-existing base overload that barely moves is suppressed (model artifact)" do
    {ol, st, rt} = categorize([flow(1, 106.0)], %{{:line, 1} => 3}, %{{:line, 1} => 105.0})
    assert {ol, st, rt} == {[], [], []}
  end

  test "pre-existing base overload that worsens significantly is reported" do
    {ol, _, _} = categorize([flow(1, 125.0)], %{{:line, 1} => 3}, %{{:line, 1} => 105.0})
    assert ol == [1]
  end

  test "handles missing base maps (everything measured against zero)" do
    {ol, st, rt} = categorize([flow(1, 50.0), flow(2, 85.0)], nil, nil)
    assert ol == []
    assert st == [2]
    assert rt == [1]
  end
end
