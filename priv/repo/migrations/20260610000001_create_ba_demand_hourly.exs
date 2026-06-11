defmodule PowerModel.Repo.Migrations.CreateBaDemandHourly do
  use Ecto.Migration

  def change do
    create table(:ba_demand_hourly) do
      add :balancing_authority_id,
          references(:balancing_authorities, on_delete: :delete_all),
          null: false

      add :timestamp_utc, :utc_datetime, null: false
      add :demand_mw, :float, null: false
      add :net_generation_mw, :float
      add :total_interchange_mw, :float
      timestamps()
    end

    create unique_index(:ba_demand_hourly, [:balancing_authority_id, :timestamp_utc])
    create index(:ba_demand_hourly, [:timestamp_utc])

    alter table(:buses) do
      add :balancing_authority_id,
          references(:balancing_authorities, on_delete: :nilify_all)
    end

    create index(:buses, [:balancing_authority_id])
  end
end
