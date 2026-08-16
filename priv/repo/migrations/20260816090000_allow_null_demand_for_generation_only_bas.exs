defmodule PowerModel.Repo.Migrations.AllowNullDemandForGenerationOnlyBas do
  @moduledoc """
  REVIEW ENE-20 (ENE20-E): a generation-only balancing authority — DEAA, GRID,
  HGMA, AVRN — publishes net generation and total interchange but leaves the
  EIA-930 demand cell blank. `demand_mw NOT NULL` meant the ingester had to
  drop the whole row, throwing away the interchange that is the only thing
  those BAs' injection can be anchored against (~1.6 GW in Western).

  Nothing is backfilled: existing rows all carry a demand value. The column
  simply stops forcing a row that has two of three series to be discarded.
  Every reader already treats a non-numeric demand as "no demand data".
  """
  use Ecto.Migration

  def up do
    alter table(:ba_demand_hourly) do
      modify :demand_mw, :float, null: true
    end
  end

  def down do
    execute "DELETE FROM ba_demand_hourly WHERE demand_mw IS NULL"

    alter table(:ba_demand_hourly) do
      modify :demand_mw, :float, null: false
    end
  end
end
