defmodule PowerModel.Demand.BAFuelHour do
  @moduledoc """
  One hour of actual net generation for one fuel within one balancing
  authority, ingested from the per-fuel columns of the EIA-930 bulk balance
  files.

  Rows are keyed by the EIA BA code (not a `balancing_authorities` FK) so the
  fuel series ingests independently of which BAs have been mapped onto the
  network; consumers join `ba_code` to `balancing_authorities.code`.

  `fuel` is one of the canonical values in `fuels/0`. `net_generation_mw` may
  be negative — storage charging is reported as negative net generation.

  Timestamps use the same hour-START convention as
  `PowerModel.Demand.BADemandHour`: a row at 18:00 covers (18:00, 19:00].
  """

  use Ecto.Schema
  import Ecto.Changeset

  @fuels ~w(coal natural_gas nuclear petroleum hydro solar wind other)

  schema "ba_fuel_hour" do
    field :ba_code, :string
    field :timestamp_utc, :utc_datetime
    field :fuel, :string
    field :net_generation_mw, :float

    timestamps()
  end

  @doc """
  The canonical fuel values stored in this table.
  """
  def fuels, do: @fuels

  def changeset(fuel_hour, attrs) do
    fuel_hour
    |> cast(attrs, [:ba_code, :timestamp_utc, :fuel, :net_generation_mw])
    |> validate_required([:ba_code, :timestamp_utc, :fuel])
    |> validate_inclusion(:fuel, @fuels)
    |> unique_constraint([:ba_code, :timestamp_utc, :fuel])
  end
end
