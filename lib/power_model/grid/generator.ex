defmodule PowerModel.Grid.Generator do
  @moduledoc """
  Power generation unit connected to a bus.

  Includes static ratings (p_max, fuel_type) and dynamic parameters
  (inertia, droop, governor time constant) used by the frequency simulator.
  """

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

    # Transient stability parameters
    field :x_d_pu, :float
    field :x_d_prime_pu, :float
    field :x_q_pu, :float
    field :x_q_prime_pu, :float
    field :t_d0_prime_s, :float
    field :t_q0_prime_s, :float
    field :ra_pu, :float
    field :d_factor, :float
    field :mva_base, :float
    field :exciter_model, :string
    field :governor_model, :string

    belongs_to :bus, PowerModel.Grid.Bus

    timestamps()
  end

  def changeset(generator, attrs) do
    generator
    |> cast(attrs, [:eia_plant_id, :fuel_type, :prime_mover, :p_max_mw, :p_min_mw,
                     :q_max_mvar, :q_min_mvar, :capacity_factor, :coordinates,
                     :status, :bus_id, :inertia_h, :droop_pct, :gov_time_constant_s,
                     :ramp_rate_mw_per_min, :marginal_cost_per_mwh, :v_set_pu,
                     :agc_participation_factor, :x_d_pu, :x_d_prime_pu,
                     :x_q_pu, :x_q_prime_pu, :t_d0_prime_s, :t_q0_prime_s,
                     :ra_pu, :d_factor, :mva_base, :exciter_model, :governor_model])
    |> validate_required([:p_max_mw])
    |> foreign_key_constraint(:bus_id)
  end
end
