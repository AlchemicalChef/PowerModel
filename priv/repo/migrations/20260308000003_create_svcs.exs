defmodule PowerModel.Repo.Migrations.CreateSvcs do
  use Ecto.Migration

  def change do
    create table(:svcs) do
      add :name, :string
      add :q_max_mvar, :float
      add :q_min_mvar, :float
      add :v_set_pu, :float, default: 1.0
      add :control_mode, :string, default: "voltage"
      add :slope_pct, :float, default: 3.0
      add :status, :string, default: "in_service"
      add :bus_id, references(:buses, on_delete: :delete_all)

      timestamps()
    end

    create index(:svcs, [:bus_id])
  end
end
