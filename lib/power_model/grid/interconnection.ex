defmodule PowerModel.Grid.Interconnection do
  @moduledoc """
  Major AC interconnection (Eastern, Western, or ERCOT).

  Buses belong to exactly one interconnection. International tie lines
  connect buses across interconnection boundaries.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "interconnections" do
    field :name, :string
    field :geometry, Geo.PostGIS.Geometry

    has_many :balancing_authorities, PowerModel.Grid.BalancingAuthority
    has_many :buses, PowerModel.Grid.Bus

    timestamps()
  end

  def changeset(interconnection, attrs) do
    interconnection
    |> cast(attrs, [:name, :geometry])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
