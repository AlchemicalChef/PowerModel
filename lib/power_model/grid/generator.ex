defmodule PowerModel.Grid.Generator do
  use Ecto.Schema
  import Ecto.Changeset

  schema "generators" do
    field :eia_plant_id, :string
    # EIA-860 "Generator ID" — unique per unit within a plant. Together with
    # eia_plant_id it forms the natural key of a unit (see the partial unique
    # index generators_eia_plant_id_generator_id_index).
    field :generator_id, :string
    field :fuel_type, :string
    field :prime_mover, :string
    field :p_max_mw, :float
    field :p_min_mw, :float, default: 0.0
    field :q_max_mvar, :float
    field :q_min_mvar, :float
    field :capacity_factor, :float
    field :coordinates, Geo.PostGIS.Geometry
    field :status, :string, default: "in_service"

    belongs_to :bus, PowerModel.Grid.Bus

    timestamps()
  end

  def changeset(generator, attrs) do
    generator
    |> cast(attrs, [
      :eia_plant_id,
      :generator_id,
      :fuel_type,
      :prime_mover,
      :p_max_mw,
      :p_min_mw,
      :q_max_mvar,
      :q_min_mvar,
      :capacity_factor,
      :coordinates,
      :status,
      :bus_id
    ])
    |> validate_required([:p_max_mw])
    |> foreign_key_constraint(:bus_id)
  end
end
