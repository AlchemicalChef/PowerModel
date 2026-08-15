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
    # EIA-860 seasonal net capability. Nameplate (`p_max_mw`) overstates what
    # a unit can actually deliver — nationally by 83.1 GW in summer — so
    # dispatch should prefer the seasonal value. NULL means EIA did not report
    # one (~0.3% of operable units); callers fall back to `p_max_mw`.
    field :summer_capacity_mw, :float
    field :winter_capacity_mw, :float
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
      :summer_capacity_mw,
      :winter_capacity_mw,
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
