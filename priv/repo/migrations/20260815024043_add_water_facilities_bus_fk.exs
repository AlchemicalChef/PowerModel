defmodule PowerModel.Repo.Migrations.AddWaterFacilitiesBusFk do
  use Ecto.Migration

  @moduledoc """
  DAT-3: `water_facilities.bus_id` was a plain integer with no foreign key,
  so deleting buses (e.g. Cleanup.cleanup_orphaned_buses) left dangling ids
  that crashed later load rebuilds. Null out any already-dangling references,
  then add a real FK with ON DELETE SET NULL so future bus deletions detach
  facilities instead of leaving them pointing at nothing.
  """

  def up do
    execute """
    UPDATE water_facilities w
    SET bus_id = NULL
    WHERE w.bus_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM buses b WHERE b.id = w.bus_id)
    """

    execute """
    ALTER TABLE water_facilities
    ADD CONSTRAINT water_facilities_bus_id_fkey
    FOREIGN KEY (bus_id) REFERENCES buses(id) ON DELETE SET NULL
    """

    create index(:water_facilities, [:bus_id])
  end

  def down do
    drop index(:water_facilities, [:bus_id])
    execute "ALTER TABLE water_facilities DROP CONSTRAINT water_facilities_bus_id_fkey"
  end
end
