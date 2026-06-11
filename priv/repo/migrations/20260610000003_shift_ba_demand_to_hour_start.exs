defmodule PowerModel.Repo.Migrations.ShiftBaDemandToHourStart do
  use Ecto.Migration

  @moduledoc """
  EIA-930 publishes "UTC Time at End of Hour"; rows were originally stored
  with that end-of-hour timestamp, so every hour lookup (which truncates the
  requested time DOWN to the hour) was served the previous hour's demand.
  Shift existing rows to hour-beginning semantics; ingestion now applies the
  same shift at parse time.
  """

  # The bulk shift transiently collides with the unique index (row at H moves
  # onto the not-yet-moved row at H-1), so the index is dropped around the
  # UPDATE. All three statements share the migration's transaction.
  def up do
    execute "DROP INDEX IF EXISTS ba_demand_hourly_balancing_authority_id_timestamp_utc_index"
    execute "UPDATE ba_demand_hourly SET timestamp_utc = timestamp_utc - interval '1 hour'"

    execute """
    CREATE UNIQUE INDEX ba_demand_hourly_balancing_authority_id_timestamp_utc_index
    ON ba_demand_hourly (balancing_authority_id, timestamp_utc)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS ba_demand_hourly_balancing_authority_id_timestamp_utc_index"
    execute "UPDATE ba_demand_hourly SET timestamp_utc = timestamp_utc + interval '1 hour'"

    execute """
    CREATE UNIQUE INDEX ba_demand_hourly_balancing_authority_id_timestamp_utc_index
    ON ba_demand_hourly (balancing_authority_id, timestamp_utc)
    """
  end
end
