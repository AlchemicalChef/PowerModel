defmodule PowerModel.Repo.Migrations.AddBusShunts do
  use Ecto.Migration

  def change do
    alter table(:buses) do
      # Fixed shunt devices (capacitor banks, reactors, filter banks).
      # MATPOWER convention: MW / MVAr injected at V = 1.0 pu; a capacitor
      # bank has bs_mvar > 0, a reactor bs_mvar < 0.
      add :gs_mw, :float, default: 0.0, null: false
      add :bs_mvar, :float, default: 0.0, null: false
    end
  end
end
