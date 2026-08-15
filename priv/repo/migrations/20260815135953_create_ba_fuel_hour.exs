defmodule PowerModel.Repo.Migrations.CreateBaFuelHour do
  use Ecto.Migration

  @moduledoc """
  Per-BA, per-hour, per-fuel net generation from the EIA-930 balance files.

  Keyed by the EIA BA code rather than a `balancing_authorities` FK: the 930
  bulk files are the authority on which BA codes exist, and fuel rows must
  ingest even for codes that carry no buses yet (the demand ingest creates
  those rows lazily). Consumers join on `balancing_authorities.code`.

  `fuel` holds one of the canonical values coal, natural_gas, nuclear,
  petroleum, hydro, solar, wind, other — EIA's 16 per-fuel columns collapsed
  onto the eight fuels the generator fleet can be partitioned into.
  """

  def change do
    create table(:ba_fuel_hour) do
      add :ba_code, :string, null: false
      add :timestamp_utc, :utc_datetime, null: false
      add :fuel, :string, null: false
      add :net_generation_mw, :float
      timestamps()
    end

    create unique_index(:ba_fuel_hour, [:ba_code, :timestamp_utc, :fuel])
    create index(:ba_fuel_hour, [:timestamp_utc])
  end
end
