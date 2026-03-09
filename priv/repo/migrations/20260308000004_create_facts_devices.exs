defmodule PowerModel.Repo.Migrations.CreateFactsDevices do
  use Ecto.Migration

  def change do
    create table(:facts_devices) do
      add :name, :string
      add :device_type, :string
      add :rated_mva, :float
      add :x_min_pu, :float
      add :x_max_pu, :float
      add :x_set_pu, :float
      add :angle_min_deg, :float
      add :angle_max_deg, :float
      add :angle_set_deg, :float
      add :status, :string, default: "in_service"
      add :line_id, references(:transmission_lines, on_delete: :nilify_all)
      add :bus_id, references(:buses, on_delete: :nilify_all)

      timestamps()
    end

    create index(:facts_devices, [:line_id])
    create index(:facts_devices, [:bus_id])
    create index(:facts_devices, [:device_type])
  end
end
