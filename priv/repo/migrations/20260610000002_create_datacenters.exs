defmodule PowerModel.Repo.Migrations.CreateDatacenters do
  use Ecto.Migration

  def up do
    create table(:datacenters) do
      add :name, :string, null: false
      add :operator, :string
      add :facility_type, :string, null: false, default: "hyperscale"
      add :coordinates, :geometry, null: false
      add :city, :string
      add :state, :string
      add :status, :string, default: "active"
      add :power_mw, :float, null: false
      add :it_load_mw, :float
      add :source, :string
      add :source_id, :string
      add :bus_id, references(:buses, on_delete: :nilify_all)
      timestamps()
    end

    create index(:datacenters, [:facility_type])
    create index(:datacenters, [:bus_id])
    create unique_index(:datacenters, [:source, :source_id])
    execute "CREATE INDEX datacenters_coordinates_gist ON datacenters USING GIST (coordinates)"

    # Allow one load row per (bus, load_type): the synthetic baseline load and
    # a flat datacenter load can coexist on the same bus.
    drop unique_index(:loads, [:bus_id])
    create unique_index(:loads, [:bus_id, :load_type])
  end

  def down do
    # Datacenter load rows would collide with the single-row-per-bus index;
    # remove them before restoring it.
    execute "DELETE FROM loads WHERE load_type = 'datacenter'"
    drop unique_index(:loads, [:bus_id, :load_type])
    create unique_index(:loads, [:bus_id])

    drop table(:datacenters)
  end
end
