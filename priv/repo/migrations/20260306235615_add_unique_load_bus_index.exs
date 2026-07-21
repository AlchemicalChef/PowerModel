defmodule PowerModel.Repo.Migrations.AddUniqueLoadBusIndex do
  use Ecto.Migration

  def change do
    # Remove duplicate loads first (keep the one with lowest id)
    execute """
            DELETE FROM loads
            WHERE id NOT IN (
              SELECT MIN(id) FROM loads GROUP BY bus_id
            )
            """,
            ""

    # Drop existing non-unique index if present, then create unique
    drop_if_exists index(:loads, [:bus_id])
    create unique_index(:loads, [:bus_id])
  end
end
