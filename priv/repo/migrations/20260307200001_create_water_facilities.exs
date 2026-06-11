defmodule PowerModel.Repo.Migrations.CreateWaterFacilities do
  use Ecto.Migration

  def change do
    create table(:water_facilities) do
      add :name, :string, null: false
      # desalination, wastewater, treatment, pump_station, reservoir
      add :facility_type, :string, null: false
      add :coordinates, :geometry, null: false
      add :city, :string
      add :county, :string
      add :state, :string, default: "CA"
      add :owner, :string
      add :status, :string, default: "active"

      # Capacity
      # million gallons per day
      add :capacity_mgd, :float
      # for reservoirs
      add :storage_acre_feet, :float

      # Power linkage
      # electrical load
      add :power_consumption_mw, :float
      # FK to generators table (if co-located)
      add :generator_id, :integer
      # FK to buses (electrical connection)
      add :bus_id, :integer

      # Source tracking
      # epa, sdcwa, carlsbad, manual
      add :source, :string
      add :source_id, :string

      timestamps()
    end

    create index(:water_facilities, [:facility_type])
    create index(:water_facilities, [:county])
    create index(:water_facilities, [:coordinates], using: :gist)
    create unique_index(:water_facilities, [:source, :source_id])
  end
end
