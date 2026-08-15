defmodule PowerModel.Repo.Migrations.AddLineEmergencyRatingsAndParamsVersion do
  use Ecto.Migration

  # REVIEW DAT-17: `rating_b_mva` and `rating_c_mva` already exist in the dev
  # database with no migration behind them (added by hand at some point), so a
  # fresh `mix ecto.setup` produced a schema that diverged from the running one.
  # `ADD COLUMN IF NOT EXISTS` makes this migration apply cleanly to both: it
  # creates the columns on a fresh database and is a no-op on the drifted one.
  #
  # rating_b_mva — 4-hour emergency rating (display/operator alarm basis)
  # rating_c_mva — 15-minute / load-dump emergency rating; the basis relays
  #                actually pick up on (see Failure.Cascade.trip_loading_pct/1)
  # params_version — ROADMAP item 8 (REVIEW DAT-18): estimators revisit rows
  #                whose stored parameters predate the current estimator, so an
  #                improved parameter table reaches existing rows instead of
  #                only filling NULLs. 0 means "never estimated by a versioned
  #                estimator".
  def up do
    execute "ALTER TABLE transmission_lines ADD COLUMN IF NOT EXISTS rating_b_mva double precision"

    execute "ALTER TABLE transmission_lines ADD COLUMN IF NOT EXISTS rating_c_mva double precision"

    execute """
    ALTER TABLE transmission_lines
    ADD COLUMN IF NOT EXISTS params_version integer NOT NULL DEFAULT 0
    """

    create_if_not_exists index(:transmission_lines, [:params_version])
  end

  def down do
    drop_if_exists index(:transmission_lines, [:params_version])

    execute "ALTER TABLE transmission_lines DROP COLUMN IF EXISTS params_version"
    execute "ALTER TABLE transmission_lines DROP COLUMN IF EXISTS rating_c_mva"
    execute "ALTER TABLE transmission_lines DROP COLUMN IF EXISTS rating_b_mva"
  end
end
