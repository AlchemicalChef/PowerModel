defmodule PowerModel.Grid.HourlyLoadProfile do
  use Ecto.Schema
  import Ecto.Changeset

  schema "hourly_load_profiles" do
    field :ba_code, :string
    field :ba_name, :string
    field :period, :utc_datetime
    field :demand_mw, :float
    field :generation_mw, :float
    field :interchange_mw, :float
    field :forecast_mw, :float

    timestamps()
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:ba_code, :ba_name, :period, :demand_mw, :generation_mw,
                     :interchange_mw, :forecast_mw])
    |> validate_required([:ba_code, :period])
    |> unique_constraint([:ba_code, :period])
  end
end
