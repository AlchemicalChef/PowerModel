defmodule Mix.Tasks.PowerModel.GenerateDemoDataTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.PowerModel.GenerateDemoData

  test "demo data targets a separate directory by default (DAT-7)" do
    assert GenerateDemoData.output_dir([]) == "priv/static/grid_data_demo"
  end

  test "--force explicitly targets the real export directory" do
    assert GenerateDemoData.output_dir(["--force"]) == "priv/static/grid_data"
  end
end
