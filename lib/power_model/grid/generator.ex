defmodule PowerModel.Grid.Generator do
  use Ecto.Schema
  import Ecto.Changeset

  schema "generators" do
    field :eia_plant_id, :string
    field :fuel_type, :string
    field :prime_mover, :string
    field :p_max_mw, :float
    field :p_min_mw, :float, default: 0.0
    field :q_max_mvar, :float
    field :q_min_mvar, :float
    field :capacity_factor, :float
    field :coordinates, Geo.PostGIS.Geometry
    field :status, :string, default: "in_service"
    field :inertia_h, :float
    field :droop_pct, :float
    field :gov_time_constant_s, :float
    field :ramp_rate_mw_per_min, :float
    field :marginal_cost_per_mwh, :float
    field :v_set_pu, :float, default: 1.0
    field :agc_participation_factor, :float, default: 0.0

    belongs_to :bus, PowerModel.Grid.Bus

    timestamps()
  end

  def changeset(generator, attrs) do
    generator
    |> cast(attrs, [:eia_plant_id, :fuel_type, :prime_mover, :p_max_mw, :p_min_mw,
                     :q_max_mvar, :q_min_mvar, :capacity_factor, :coordinates,
                     :status, :bus_id, :inertia_h, :droop_pct, :gov_time_constant_s,
                     :ramp_rate_mw_per_min, :marginal_cost_per_mwh, :v_set_pu,
                     :agc_participation_factor])
    |> validate_required([:p_max_mw])
    |> foreign_key_constraint(:bus_id)
  end
end
