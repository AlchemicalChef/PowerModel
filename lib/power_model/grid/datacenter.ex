defmodule PowerModel.Grid.Datacenter do
  @moduledoc """
  A datacenter campus drawing power from the grid.

  `power_mw` is the estimated total facility draw the grid sees (IT load plus
  cooling/overhead). Datacenter demand is modeled as a flat 24/7 load: the
  corresponding `loads` rows carry `load_type: "datacenter"` and are held
  constant by `PowerModel.Demand` hourly scaling.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @facility_types ~w(hyperscale colocation ai_training enterprise crypto)

  schema "datacenters" do
    field :name, :string
    field :operator, :string
    field :facility_type, :string, default: "hyperscale"
    field :coordinates, Geo.PostGIS.Geometry
    field :city, :string
    field :state, :string
    field :status, :string, default: "active"
    field :power_mw, :float
    field :it_load_mw, :float
    field :source, :string
    field :source_id, :string

    belongs_to :bus, PowerModel.Grid.Bus

    timestamps()
  end

  def changeset(datacenter, attrs) do
    datacenter
    |> cast(attrs, [
      :name,
      :operator,
      :facility_type,
      :coordinates,
      :city,
      :state,
      :status,
      :power_mw,
      :it_load_mw,
      :source,
      :source_id,
      :bus_id
    ])
    |> validate_required([:name, :facility_type, :coordinates, :power_mw])
    |> validate_inclusion(:facility_type, @facility_types)
    |> validate_number(:power_mw, greater_than: 0.0)
    |> unique_constraint([:source, :source_id])
    |> foreign_key_constraint(:bus_id)
  end

  def facility_types, do: @facility_types
end
