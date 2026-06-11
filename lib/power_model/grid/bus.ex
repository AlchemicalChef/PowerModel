defmodule PowerModel.Grid.Bus do
  @moduledoc """
  Electrical bus (node) in the power grid network.

  Bus types follow the standard power flow convention:
    - 1 (PQ): load bus with specified P and Q
    - 2 (PV): generator bus with specified P and voltage setpoint
    - 3 (Slack/Swing): reference bus that absorbs power mismatch
  """

  use Ecto.Schema
  import Ecto.Changeset

  @bus_types %{pq: 1, pv: 2, slack: 3}

  schema "buses" do
    field :bus_type, :integer, default: 1
    field :base_kv, :float
    field :vm_pu, :float, default: 1.0
    field :va_rad, :float, default: 0.0
    field :b_shunt_mvar, :float, default: 0.0
    field :coordinates, Geo.PostGIS.Geometry
    field :source, :string
    field :source_id, :string

    belongs_to :interconnection, PowerModel.Grid.Interconnection

    has_many :generators, PowerModel.Grid.Generator
    has_many :loads, PowerModel.Grid.Load
    has_many :from_lines, PowerModel.Grid.TransmissionLine, foreign_key: :from_bus_id
    has_many :to_lines, PowerModel.Grid.TransmissionLine, foreign_key: :to_bus_id

    timestamps()
  end

  def changeset(bus, attrs) do
    bus
    |> cast(attrs, [
      :bus_type,
      :base_kv,
      :vm_pu,
      :va_rad,
      :b_shunt_mvar,
      :coordinates,
      :source,
      :source_id,
      :interconnection_id
    ])
    |> validate_required([:bus_type, :base_kv])
    |> validate_inclusion(:bus_type, Map.values(@bus_types))
    |> unique_constraint([:source, :source_id])
    |> foreign_key_constraint(:interconnection_id)
  end

  def bus_types, do: @bus_types
end
