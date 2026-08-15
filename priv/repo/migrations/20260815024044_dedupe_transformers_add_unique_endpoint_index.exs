defmodule PowerModel.Repo.Migrations.DedupeTransformersAddUniqueEndpointIndex do
  use Ecto.Migration

  @moduledoc """
  LIN-4 / DAT-1: transformers had no natural key, so every `map_buses` re-run
  inserted a duplicate bank between the same two buses (`on_conflict: :nothing`
  without a conflict target is a no-op guard). Delete duplicates keeping the
  oldest row per (from_bus_id, to_bus_id), then enforce uniqueness so the
  BusMapper upsert (`conflict_target: [:from_bus_id, :to_bus_id]`) works.
  """

  def up do
    execute """
    DELETE FROM transformers t
    USING transformers keep
    WHERE t.from_bus_id = keep.from_bus_id
      AND t.to_bus_id = keep.to_bus_id
      AND t.id > keep.id
    """

    create unique_index(:transformers, [:from_bus_id, :to_bus_id])
  end

  def down do
    drop unique_index(:transformers, [:from_bus_id, :to_bus_id])
  end
end
