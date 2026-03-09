defmodule PowerModel.Repo.Migrations.CreateHourlyLoadProfiles do
  use Ecto.Migration

  def change do
    create table(:hourly_load_profiles) do
      add :ba_code, :string, null: false
      add :ba_name, :string
      add :period, :utc_datetime, null: false
      add :demand_mw, :float
      add :generation_mw, :float
      add :interchange_mw, :float
      add :forecast_mw, :float

      timestamps()
    end

    create unique_index(:hourly_load_profiles, [:ba_code, :period])
    create index(:hourly_load_profiles, [:ba_code])
    create index(:hourly_load_profiles, [:period])

    create table(:hourly_generation_mix) do
      add :ba_code, :string, null: false
      add :period, :utc_datetime, null: false
      add :fuel_type, :string, null: false
      add :generation_mw, :float

      timestamps()
    end

    create unique_index(:hourly_generation_mix, [:ba_code, :period, :fuel_type])
    create index(:hourly_generation_mix, [:ba_code])
  end
end
