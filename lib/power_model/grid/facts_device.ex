defmodule PowerModel.Grid.FACTSDevice do
  @moduledoc """
  Schema for Flexible AC Transmission System (FACTS) devices.

  Covers series-connected devices that modify the effective impedance or
  phase angle of a transmission line:

    * `"TCSC"` -- Thyristor-Controlled Series Capacitor.  Adjusts the
      effective series reactance of the line between `x_min_pu` (fully
      compensated) and `x_max_pu`.
    * `"phase_shifter"` -- Phase-Shifting Transformer.  Inserts a
      controllable phase angle between `angle_min_deg` and `angle_max_deg`.
    * `"SSSC"` -- Static Synchronous Series Compensator.  Injects a
      controllable series voltage to emulate variable reactance.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "facts_devices" do
    field :name, :string
    field :device_type, :string
    field :rated_mva, :float
    field :x_min_pu, :float
    field :x_max_pu, :float
    field :x_set_pu, :float
    field :angle_min_deg, :float
    field :angle_max_deg, :float
    field :angle_set_deg, :float
    field :status, :string, default: "in_service"

    belongs_to :line, PowerModel.Grid.TransmissionLine
    belongs_to :bus, PowerModel.Grid.Bus

    timestamps()
  end

  @cast_fields [
    :name,
    :device_type,
    :rated_mva,
    :x_min_pu,
    :x_max_pu,
    :x_set_pu,
    :angle_min_deg,
    :angle_max_deg,
    :angle_set_deg,
    :status,
    :line_id,
    :bus_id
  ]

  @valid_device_types ["TCSC", "phase_shifter", "SSSC"]

  def changeset(device, attrs) do
    device
    |> cast(attrs, @cast_fields)
    |> validate_required([:device_type])
    |> validate_inclusion(:device_type, @valid_device_types)
    |> foreign_key_constraint(:line_id)
    |> foreign_key_constraint(:bus_id)
  end
end
