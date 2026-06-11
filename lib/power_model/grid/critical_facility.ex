defmodule PowerModel.Grid.CriticalFacility do
  @moduledoc """
  Critical infrastructure facility (hospital, fire station, police station, EMS station)
  linked to the power grid via a bus for interdependency analysis.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @categories ~w(hospital fire_station police_station ems_station)

  schema "critical_facilities" do
    field :name, :string
    field :category, :string
    field :facility_type, :string
    field :coordinates, Geo.PostGIS.Geometry
    field :address, :string
    field :city, :string
    field :county, :string
    field :state, :string
    field :zip, :string
    field :owner, :string
    field :status, :string, default: "active"

    field :beds, :integer
    field :trauma, :string
    field :helipad, :boolean, default: false
    field :total_staff, :integer

    field :estimated_power_mw, :float
    field :bus_id, :integer

    field :source, :string
    field :source_id, :string

    timestamps()
  end

  def changeset(facility, attrs) do
    facility
    |> cast(attrs, [
      :name,
      :category,
      :facility_type,
      :coordinates,
      :address,
      :city,
      :county,
      :state,
      :zip,
      :owner,
      :status,
      :beds,
      :trauma,
      :helipad,
      :total_staff,
      :estimated_power_mw,
      :bus_id,
      :source,
      :source_id
    ])
    |> validate_required([:name, :category, :coordinates])
    |> validate_inclusion(:category, @categories)
    |> unique_constraint([:source, :source_id])
    |> foreign_key_constraint(:bus_id)
  end

  def categories, do: @categories
end
