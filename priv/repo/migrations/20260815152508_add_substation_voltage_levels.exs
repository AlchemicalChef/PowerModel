defmodule PowerModel.Repo.Migrations.AddSubstationVoltageLevels do
  use Ecto.Migration

  @moduledoc """
  LIN-5 / DAT-9: the per-substation clustered voltage list is computed at
  ingest (Substations.cluster_voltage_levels/1) and then thrown away — only
  its max and min survive. Everything between (a 500/345/138/115 yard's 345
  and 138) has no bus, so EHV line endpoints snap to whatever level happens
  to be in the +/-10% window and multi-level substations get one fictitious
  transformer welding the extremes.

  Store the whole list. `max_voltage_kv` / `min_voltage_kv` stay for
  compatibility; existing rows are backfilled from them so the column is
  never NULL for a substation that has any voltage at all.
  """

  def up do
    alter table(:substations) do
      add :voltage_levels, {:array, :float}
    end

    # Backfill: the pre-existing rows only ever knew max/min. Descending
    # order matches what the ingest now writes.
    execute """
    UPDATE substations
    SET voltage_levels = CASE
      WHEN max_voltage_kv IS NULL AND min_voltage_kv IS NULL THEN ARRAY[]::double precision[]
      WHEN max_voltage_kv IS NULL THEN ARRAY[min_voltage_kv]
      WHEN min_voltage_kv IS NULL OR min_voltage_kv = max_voltage_kv THEN ARRAY[max_voltage_kv]
      WHEN min_voltage_kv > max_voltage_kv THEN ARRAY[min_voltage_kv, max_voltage_kv]
      ELSE ARRAY[max_voltage_kv, min_voltage_kv]
    END
    """
  end

  def down do
    alter table(:substations) do
      remove :voltage_levels
    end
  end
end
