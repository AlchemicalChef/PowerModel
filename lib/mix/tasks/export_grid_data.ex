defmodule Mix.Tasks.PowerModel.ExportGridData do
  @moduledoc """
  Export grid data as compact binary files for frontend consumption.

  ## Usage

      mix power_model.export_grid_data

  Writes to priv/static/grid_data/:
    - generators.bin
    - transmission.bin
    - substations.bin
    - water_facilities.json
    - datacenters.json

  In production releases use `PowerModel.Release.export_grid_data/0` instead
  (e.g. `bin/power_model rpc "PowerModel.Release.export_grid_data()"`).
  """

  use Mix.Task

  @shortdoc "Export grid data as binary files for frontend"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    PowerModel.GridExport.run("priv/static/grid_data")
  end
end
