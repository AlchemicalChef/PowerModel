defmodule PowerModel.Repo.Migrations.AddGeneratorGridVoltage do
  use Ecto.Migration

  @moduledoc """
  EIA-860's plant-level "Grid Voltage (kV)" — where the plant actually
  interconnects — as a generator column (REVIEW CAS-32). Pure DDL; the
  backfill and the placement re-map are the NEXT migration, because a column
  added on the migrator's connection is not yet visible to the pool
  connections `Repo` data calls would use.
  """

  def change do
    alter table(:generators) do
      add :grid_voltage_kv, :float
    end
  end
end
