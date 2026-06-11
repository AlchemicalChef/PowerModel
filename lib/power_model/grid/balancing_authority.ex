defmodule PowerModel.Grid.BalancingAuthority do
  use Ecto.Schema
  import Ecto.Changeset

  schema "balancing_authorities" do
    field :code, :string
    field :name, :string
    field :geometry, Geo.PostGIS.Geometry

    belongs_to :interconnection, PowerModel.Grid.Interconnection

    has_many :buses, PowerModel.Grid.Bus
    has_many :demand_hours, PowerModel.Demand.BADemandHour

    timestamps()
  end

  def changeset(ba, attrs) do
    ba
    |> cast(attrs, [:code, :name, :geometry, :interconnection_id])
    |> validate_required([:code, :name])
    |> unique_constraint(:code)
    |> foreign_key_constraint(:interconnection_id)
  end
end
