defmodule PowerModel.Repo.Migrations.ExcludeRealConstraints do
  use Ecto.Migration

  @moduledoc """
  Re-derives the inferred circuits with the ISOs' reported binding elements
  excluded (REVIEW EXT-1). Six ERCOT bottlenecks — Frontera-S. Mission and
  Bruni 138 kV among them — were overloaded at rest in the raw model and had
  been given circuits by the at-rest pass; the real market has them at their
  limit and manages them by re-dispatch. `CapacityInference` now reads
  `data/vendored/known_binding_elements_*.csv` and never adds capacity on
  those branches; this migration re-runs both passes so the stored network
  reflects that. Their at-rest overload therefore comes back, honestly, until
  transmission-constrained re-dispatch exists.
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
