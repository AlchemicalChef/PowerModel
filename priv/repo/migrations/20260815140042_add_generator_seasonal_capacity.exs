defmodule PowerModel.Repo.Migrations.AddGeneratorSeasonalCapacity do
  use Ecto.Migration

  @moduledoc """
  Adds EIA-860 seasonal net capability to generators.

  Nameplate capacity is a rating plate number, not a dispatchable limit: the
  measured national fleet reports 83.1 GW less summer capability than
  nameplate, concentrated in the gas fleet that provides operating reserve.
  Dispatching against nameplate therefore invents reserve that does not exist
  on the hot afternoons when it matters most.

  Both columns are nullable: EIA leaves them blank for ~0.3% of operable
  units, and a NULL means "not reported" — consumers fall back to `p_max_mw`
  rather than reading a fabricated zero.
  """

  def change do
    alter table(:generators) do
      add :summer_capacity_mw, :float
      add :winter_capacity_mw, :float
    end
  end
end
