defmodule PowerModel.Repo.Migrations.AllowNullBusIds do
  use Ecto.Migration

  def change do
    # Allow NULL bus_id during initial ingestion (before bus mapping)
    alter table(:generators) do
      modify :bus_id, :bigint, null: true, from: {:bigint, null: false}
    end

    alter table(:transmission_lines) do
      modify :from_bus_id, :bigint, null: true, from: {:bigint, null: false}
      modify :to_bus_id, :bigint, null: true, from: {:bigint, null: false}
    end

    alter table(:loads) do
      modify :bus_id, :bigint, null: true, from: {:bigint, null: false}
    end
  end
end
