defmodule PowerModel.Repo.Migrations.AddBusShuntSusceptance do
  use Ecto.Migration

  def change do
    alter table(:buses) do
      add :b_shunt_mvar, :float, default: 0.0
    end
  end
end
