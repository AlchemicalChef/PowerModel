defmodule PowerModel.Demographics.CountyPopulation do
  @moduledoc """
  County resident population (Census Bureau vintage estimate) with the
  county's interior point as coordinates. Used as spatial weights when
  distributing synthetic baseline load across PQ buses.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "county_population" do
    field :fips, :string
    field :name, :string
    field :state, :string
    field :population, :integer
    field :coordinates, Geo.PostGIS.Geometry

    timestamps()
  end

  def changeset(county, attrs) do
    county
    |> cast(attrs, [:fips, :name, :state, :population, :coordinates])
    |> validate_required([:fips, :name, :state, :population, :coordinates])
    |> unique_constraint(:fips)
  end
end
