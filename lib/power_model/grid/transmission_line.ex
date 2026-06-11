defmodule PowerModel.Grid.TransmissionLine do
  use Ecto.Schema
  import Ecto.Changeset

  schema "transmission_lines" do
    field :voltage_kv, :float
    field :r_pu, :float
    field :x_pu, :float
    field :b_pu, :float
    field :rating_a_mva, :float
    field :length_km, :float
    field :geometry, Geo.PostGIS.Geometry
    field :status, :string, default: "in_service"
    field :source, :string
    field :source_id, :string
    field :line_type, :string
    field :owner, :string
    field :sub_1, :string
    field :sub_2, :string
    field :naics_code, :string
    field :naics_desc, :string

    belongs_to :from_bus, PowerModel.Grid.Bus
    belongs_to :to_bus, PowerModel.Grid.Bus

    timestamps()
  end

  @cast_fields [
    :voltage_kv, :r_pu, :x_pu, :b_pu, :rating_a_mva, :length_km,
    :geometry, :status, :source, :source_id, :from_bus_id, :to_bus_id,
    :line_type, :owner, :sub_1, :sub_2, :naics_code, :naics_desc
  ]

  def changeset(line, attrs) do
    line
    |> cast(attrs, @cast_fields)
    |> validate_required([:voltage_kv])
    |> validate_number(:r_pu, greater_than_or_equal_to: 0)
    |> validate_number(:x_pu, greater_than: 0)
    |> unique_constraint([:source, :source_id])
    |> foreign_key_constraint(:from_bus_id)
    |> foreign_key_constraint(:to_bus_id)
  end
end
