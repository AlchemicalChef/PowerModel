defmodule PowerModel.Grid.WaterFacility do
  @moduledoc """
  Water infrastructure facility (treatment plant, pump station, reservoir)
  linked to the power grid via a bus for interdependency analysis.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "water_facilities" do
    field :name, :string
    field :facility_type, :string
    field :coordinates, Geo.PostGIS.Geometry
    field :city, :string
    field :county, :string
    field :state, :string, default: "CA"
    field :owner, :string
    field :status, :string, default: "active"

    field :capacity_mgd, :float
    field :storage_acre_feet, :float

    field :power_consumption_mw, :float
    field :generator_id, :integer
    field :bus_id, :integer

    field :source, :string
    field :source_id, :string

    timestamps()
  end

  def changeset(facility, attrs) do
    facility
    |> cast(attrs, [
      :name, :facility_type, :coordinates, :city, :county, :state,
      :owner, :status, :capacity_mgd, :storage_acre_feet,
      :power_consumption_mw, :generator_id, :bus_id, :source, :source_id
    ])
    |> validate_required([:name, :facility_type, :coordinates])
    |> validate_inclusion(:facility_type, ~w(desalination wastewater treatment pump_station reservoir pipeline))
    |> unique_constraint([:source, :source_id])
  end
end
