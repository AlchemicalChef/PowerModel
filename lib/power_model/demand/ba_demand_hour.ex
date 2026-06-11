defmodule PowerModel.Demand.BADemandHour do
  @moduledoc """
  One hour of actual electricity demand for a balancing authority,
  ingested from EIA-930 bulk balance files.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "ba_demand_hourly" do
    field :timestamp_utc, :utc_datetime
    field :demand_mw, :float
    field :net_generation_mw, :float
    field :total_interchange_mw, :float

    belongs_to :balancing_authority, PowerModel.Grid.BalancingAuthority

    timestamps()
  end

  def changeset(demand_hour, attrs) do
    demand_hour
    |> cast(attrs, [
      :balancing_authority_id,
      :timestamp_utc,
      :demand_mw,
      :net_generation_mw,
      :total_interchange_mw
    ])
    |> validate_required([:balancing_authority_id, :timestamp_utc, :demand_mw])
    |> unique_constraint([:balancing_authority_id, :timestamp_utc])
    |> foreign_key_constraint(:balancing_authority_id)
  end
end
