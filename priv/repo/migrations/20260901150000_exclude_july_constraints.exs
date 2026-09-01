defmodule PowerModel.Repo.Migrations.ExcludeJulyConstraints do
  use Ecto.Migration

  @moduledoc """
  Re-derives both capacity passes with the season-matched July constraint
  records excluded (REVIEW EXT-4). The winter-week exclusion list
  (20260901140000) did not know MISO's July constraints, so 12 of the 34
  July elements the congestion score found in the model had been given
  inferred circuits — the EXT-1 failure recurring on a new record set.
  `known_binding_elements_2026-09-01_jul.csv` (58 rows, both ISOs) is read
  by `CapacityInference` like every other exclusion file; this migration
  re-runs the passes so the stored network reflects it. No-op on an empty
  database: both passes iterate the interconnections that exist.
  """

  def up do
    PowerModel.Ingestion.CapacityInference.run()
    opts = [alpha_steps: [0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 1.0], target: 1.0]
    PowerModel.Ingestion.CapacityInference.run_ceiling(opts)
  end

  def down do
    :ok
  end
end
