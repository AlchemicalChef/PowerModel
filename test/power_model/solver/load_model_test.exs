defmodule PowerModel.Solver.LoadModelTest do
  use ExUnit.Case, async: true

  alias PowerModel.Solver.LoadModel

  doctest PowerModel.Solver.LoadModel

  test "accepts Ecto structs, not just plain maps" do
    # Production loads are %Load{} structs; Access syntax (load[:key]) would
    # crash on them. Regression for the AC-refinement crash.
    load = %PowerModel.Grid.Load{p_mw: 100.0, q_mvar: 30.0, load_type: "constant_power"}

    # k = 0.0 isolates this from distribution compensation: what is under test
    # is struct access, not the reactive model.
    assert {100.0, 30.0} = LoadModel.effective_load(load, 1.0, 0.0)
  end

  test "handles loads with nil q_mvar and load_type" do
    load = %PowerModel.Grid.Load{p_mw: 50.0}

    assert {50.0, +0.0} = LoadModel.effective_load(load, 1.0)
  end
end
