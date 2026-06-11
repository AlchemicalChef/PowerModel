defmodule PowerModel.Grid.Substation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "substations" do
    field :name, :string
    field :max_voltage_kv, :float
    field :min_voltage_kv, :float
    field :coordinates, Geo.PostGIS.Geometry
    field :hifld_id, :string
    field :status, :string, default: "in_service"

    timestamps()
  end

  def changeset(substation, attrs) do
    substation
    |> cast(attrs, [:name, :max_voltage_kv, :min_voltage_kv, :coordinates,
                     :hifld_id, :status])
    |> validate_required([:name])
    |> unique_constraint(:hifld_id)
  end
end
