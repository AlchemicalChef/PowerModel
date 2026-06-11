defmodule PowerModel.Repo.Migrations.CreateGridTables do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS postgis"

    # Interconnections
    create table(:interconnections) do
      add :name, :string, null: false
      add :geometry, :geometry
      timestamps()
    end
    create unique_index(:interconnections, [:name])

    # Balancing Authorities
    create table(:balancing_authorities) do
      add :code, :string, null: false
      add :name, :string, null: false
      add :geometry, :geometry
      add :interconnection_id, references(:interconnections, on_delete: :restrict)
      timestamps()
    end
    create unique_index(:balancing_authorities, [:code])
    create index(:balancing_authorities, [:interconnection_id])

    # Buses
    create table(:buses) do
      add :bus_type, :integer, null: false, default: 1
      add :base_kv, :float, null: false
      add :vm_pu, :float, default: 1.0
      add :va_rad, :float, default: 0.0
      add :coordinates, :geometry
      add :source, :string
      add :source_id, :string
      add :interconnection_id, references(:interconnections, on_delete: :restrict)
      timestamps()
    end
    create unique_index(:buses, [:source, :source_id])
    create index(:buses, [:interconnection_id])
    create index(:buses, [:bus_type])
    create index(:buses, [:base_kv])
    execute "CREATE INDEX buses_coordinates_gist ON buses USING GIST (coordinates)"

    # Generators
    create table(:generators) do
      add :eia_plant_id, :string
      add :fuel_type, :string
      add :prime_mover, :string
      add :p_max_mw, :float, null: false
      add :p_min_mw, :float, default: 0.0
      add :q_max_mvar, :float
      add :q_min_mvar, :float
      add :capacity_factor, :float
      add :coordinates, :geometry
      add :status, :string, default: "in_service"
      add :bus_id, references(:buses, on_delete: :restrict), null: false
      timestamps()
    end
    create index(:generators, [:bus_id])
    create index(:generators, [:fuel_type])
    execute "CREATE INDEX generators_coordinates_gist ON generators USING GIST (coordinates)"

    # Transmission Lines
    create table(:transmission_lines) do
      add :voltage_kv, :float, null: false
      add :r_pu, :float
      add :x_pu, :float
      add :b_pu, :float
      add :rating_a_mva, :float
      add :length_km, :float
      add :geometry, :geometry
      add :status, :string, default: "in_service"
      add :source, :string
      add :source_id, :string
      add :from_bus_id, references(:buses, on_delete: :restrict), null: false
      add :to_bus_id, references(:buses, on_delete: :restrict), null: false
      timestamps()
    end
    create unique_index(:transmission_lines, [:source, :source_id])
    create index(:transmission_lines, [:from_bus_id])
    create index(:transmission_lines, [:to_bus_id])
    create index(:transmission_lines, [:voltage_kv])
    execute "CREATE INDEX transmission_lines_geometry_gist ON transmission_lines USING GIST (geometry)"

    # Loads
    create table(:loads) do
      add :p_mw, :float, null: false
      add :q_mvar, :float
      add :load_type, :string, default: "constant_power"
      add :status, :string, default: "in_service"
      add :bus_id, references(:buses, on_delete: :restrict), null: false
      timestamps()
    end
    create index(:loads, [:bus_id])

    # Substations
    create table(:substations) do
      add :name, :string, null: false
      add :max_voltage_kv, :float
      add :min_voltage_kv, :float
      add :coordinates, :geometry
      add :hifld_id, :string
      add :status, :string, default: "in_service"
      timestamps()
    end
    create unique_index(:substations, [:hifld_id])
    execute "CREATE INDEX substations_coordinates_gist ON substations USING GIST (coordinates)"

    # Transformers
    create table(:transformers) do
      add :rated_mva, :float, null: false
      add :r_pu, :float
      add :x_pu, :float, null: false
      add :tap_ratio, :float, default: 1.0
      add :status, :string, default: "in_service"
      add :from_bus_id, references(:buses, on_delete: :restrict), null: false
      add :to_bus_id, references(:buses, on_delete: :restrict), null: false
      timestamps()
    end
    create index(:transformers, [:from_bus_id])
    create index(:transformers, [:to_bus_id])

    # Simulation Scenarios
    create table(:simulation_scenarios) do
      add :name, :string, null: false
      add :base_mva, :float, default: 100.0
      add :solver_config, :map, default: %{}
      add :status, :string, default: "pending"
      add :interconnection_id, references(:interconnections, on_delete: :restrict)
      timestamps()
    end

    # Simulation Results
    create table(:simulation_results) do
      add :vm_pu, :float
      add :va_rad, :float
      add :p_gen_mw, :float
      add :q_gen_mvar, :float
      add :p_load_mw, :float
      add :q_load_mvar, :float
      add :scenario_id, references(:simulation_scenarios, on_delete: :delete_all), null: false
      add :bus_id, references(:buses, on_delete: :restrict), null: false
      timestamps()
    end
    create index(:simulation_results, [:scenario_id])
    create index(:simulation_results, [:bus_id])
    create unique_index(:simulation_results, [:scenario_id, :bus_id])

    # Failure Events
    create table(:failure_events) do
      add :step, :integer, null: false
      add :component_type, :string, null: false
      add :component_id, :integer, null: false
      add :failure_cause, :string, null: false
      add :details, :map, default: %{}
      add :scenario_id, references(:simulation_scenarios, on_delete: :delete_all), null: false
      timestamps()
    end
    create index(:failure_events, [:scenario_id])
    create index(:failure_events, [:scenario_id, :step])
  end

  def down do
    drop table(:failure_events)
    drop table(:simulation_results)
    drop table(:simulation_scenarios)
    drop table(:transformers)
    drop table(:substations)
    drop table(:loads)
    drop table(:transmission_lines)
    drop table(:generators)
    drop table(:buses)
    drop table(:balancing_authorities)
    drop table(:interconnections)
    execute "DROP EXTENSION IF EXISTS postgis"
  end
end
