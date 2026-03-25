defmodule PowerModel.Repo.Migrations.CreateCriticalFacilities do
  use Ecto.Migration

  def change do
    create table(:critical_facilities) do
      add :name, :string, null: false
      add :category, :string, null: false
      add :facility_type, :string
      add :coordinates, :geometry, null: false
      add :address, :string
      add :city, :string
      add :county, :string
      add :state, :string
      add :zip, :string
      add :owner, :string
      add :status, :string, default: "active"

      # Hospital-specific
      add :beds, :integer
      add :trauma, :string
      add :helipad, :boolean, default: false
      add :total_staff, :integer

      # Grid linkage
      add :estimated_power_mw, :float
      add :bus_id, references(:buses, on_delete: :nilify_all)

      # Source tracking
      add :source, :string
      add :source_id, :string

      timestamps()
    end

    create index(:critical_facilities, [:category])
    create index(:critical_facilities, [:state])
    create index(:critical_facilities, [:bus_id])
    create index(:critical_facilities, [:coordinates], using: :gist)
    create unique_index(:critical_facilities, [:source, :source_id])
  end
end
