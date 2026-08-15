defmodule PowerModel.Grid.Substation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "substations" do
    field :name, :string
    field :max_voltage_kv, :float
    field :min_voltage_kv, :float
    # Every distinct voltage level in the yard, descending, after the 5%
    # near-duplicate clustering of Substations.cluster_voltage_levels/1.
    # `max_voltage_kv`/`min_voltage_kv` are the head and tail of this list,
    # kept because older code and exports read them; the levels BETWEEN them
    # exist only here, and BusMapper gives each one its own bus (LIN-5).
    field :voltage_levels, {:array, :float}
    field :coordinates, Geo.PostGIS.Geometry
    field :hifld_id, :string
    field :status, :string, default: "in_service"

    timestamps()
  end

  def changeset(substation, attrs) do
    substation
    |> cast(attrs, [
      :name,
      :max_voltage_kv,
      :min_voltage_kv,
      :voltage_levels,
      :coordinates,
      :hifld_id,
      :status
    ])
    |> validate_required([:name])
    |> unique_constraint(:hifld_id)
  end
end
