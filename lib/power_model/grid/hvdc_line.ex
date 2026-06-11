defmodule PowerModel.Grid.HVDCLine do
  @moduledoc """
  Schema for High-Voltage Direct Current (HVDC) transmission lines.

  HVDC lines connect two AC buses through rectifier and inverter converter
  stations.  They are modelled as scheduled active power injections/withdrawals
  at the terminal buses rather than as part of the AC admittance matrix.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "hvdc_lines" do
    field :name, :string
    field :rated_mw, :float
    field :voltage_kv, :float
    field :p_schedule_mw, :float
    field :control_mode, :string, default: "constant_power"
    field :converter_loss_pct, :float, default: 1.5
    field :converter_q_factor, :float, default: 0.5
    field :status, :string, default: "in_service"
    field :source, :string
    field :source_id, :string

    belongs_to :rectifier_bus, PowerModel.Grid.Bus
    belongs_to :inverter_bus, PowerModel.Grid.Bus

    timestamps()
  end

  @cast_fields [
    :name,
    :rated_mw,
    :voltage_kv,
    :p_schedule_mw,
    :control_mode,
    :converter_loss_pct,
    :converter_q_factor,
    :status,
    :source,
    :source_id,
    :rectifier_bus_id,
    :inverter_bus_id
  ]

  def changeset(hvdc, attrs) do
    hvdc
    |> cast(attrs, @cast_fields)
    |> validate_required([:name, :rated_mw])
    |> foreign_key_constraint(:rectifier_bus_id)
    |> foreign_key_constraint(:inverter_bus_id)
  end
end
