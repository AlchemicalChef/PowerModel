defmodule PowerModel.Repo.Migrations.CreateCountyPopulation do
  use Ecto.Migration

  def change do
    create table(:county_population) do
      add :fips, :string, null: false, size: 5
      add :name, :string, null: false
      add :state, :string, null: false
      add :population, :integer, null: false
      add :coordinates, :geometry, null: false
      timestamps()
    end

    create unique_index(:county_population, [:fips])
  end
end
