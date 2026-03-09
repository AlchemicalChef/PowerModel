defmodule PowerModel.Repo.Migrations.CreateHvdcLines do
  use Ecto.Migration

  def change do
    create table(:hvdc_lines) do
      add :name, :string
      add :rated_mw, :float
      add :voltage_kv, :float
      add :p_schedule_mw, :float
      add :control_mode, :string, default: "constant_power"
      add :converter_loss_pct, :float, default: 1.5
      add :converter_q_factor, :float, default: 0.5
      add :status, :string, default: "in_service"
      add :source, :string
      add :source_id, :string
      add :rectifier_bus_id, references(:buses, on_delete: :nilify_all)
      add :inverter_bus_id, references(:buses, on_delete: :nilify_all)

      timestamps()
    end

    create index(:hvdc_lines, [:rectifier_bus_id])
    create index(:hvdc_lines, [:inverter_bus_id])
  end
end
