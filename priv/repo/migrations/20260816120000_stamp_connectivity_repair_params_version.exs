defmodule PowerModel.Repo.Migrations.StampConnectivityRepairParamsVersion do
  use Ecto.Migration

  @moduledoc """
  Stamps the `connectivity_repair` lines as parameter-current so a parameter
  recompute cannot silently overwrite them.

  PROVENANCE: these 5,628 rows are authored by `Ingestion.BusMapper`, not by
  `Ingestion.ParameterEstimator`. Each carries the impedance of the real joint
  distance the mapper welded two same-voltage yards across — distances short
  enough that 5,628 of them sit below the estimator's own write-time clamp
  (smallest 2.531e-5 pu). They are real values from a different author, and
  the estimator has no geometry with which to re-derive them.

  They were inserted at `params_version = 0`, and the estimator recomputes
  every row stamped below its current version. Until now the only thing
  keeping them was that no full recompute had run since they were written; the
  next one would have replaced every repaired impedance with a class-table
  guess against a default length.

  The durable fix is in the estimator, which now lists `connectivity_repair`
  among `@externally_authored_sources` and never selects these rows at all.
  This stamp is the second line of defence: even if that list is edited, the
  version predicate no longer matches. `3` is written literally rather than
  read from `ParameterEstimator.params_version/0` so re-running this migration
  years from now reproduces the same state it produced today.
  """

  def up do
    execute("""
    UPDATE transmission_lines
       SET params_version = 3, updated_at = now()
     WHERE source = 'connectivity_repair'
       AND params_version < 3
    """)
  end

  def down do
    execute("""
    UPDATE transmission_lines
       SET params_version = 0, updated_at = now()
     WHERE source = 'connectivity_repair'
    """)
  end
end
