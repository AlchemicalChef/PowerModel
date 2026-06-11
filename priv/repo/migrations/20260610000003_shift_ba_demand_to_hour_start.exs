defmodule PowerModel.Repo.Migrations.ShiftBaDemandToHourStart do
  use Ecto.Migration

  @moduledoc """
  EIA-930 publishes "UTC Time at End of Hour"; rows were originally stored
  with that end-of-hour timestamp, so every hour lookup (which truncates the
  requested time DOWN to the hour) was served the previous hour's demand.
  Shift existing rows to hour-beginning semantics; ingestion now applies the
  same shift at parse time.
  """

  def up do
    execute "UPDATE ba_demand_hourly SET timestamp_utc = timestamp_utc - interval '1 hour'"
  end

  def down do
    execute "UPDATE ba_demand_hourly SET timestamp_utc = timestamp_utc + interval '1 hour'"
  end
end
