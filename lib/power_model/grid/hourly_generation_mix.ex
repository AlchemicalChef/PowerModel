defmodule PowerModel.Grid.HourlyGenerationMix do
  use Ecto.Schema
  import Ecto.Changeset

  schema "hourly_generation_mix" do
    field :ba_code, :string
    field :period, :utc_datetime
    field :fuel_type, :string
    field :generation_mw, :float

    timestamps()
  end

  def changeset(mix, attrs) do
    mix
    |> cast(attrs, [:ba_code, :period, :fuel_type, :generation_mw])
    |> validate_required([:ba_code, :period, :fuel_type])
    |> unique_constraint([:ba_code, :period, :fuel_type])
  end
end
