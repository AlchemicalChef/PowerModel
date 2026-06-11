defmodule PowerModel.Grid.Transformer do
  @moduledoc """
  Power transformer connecting buses at different voltage levels.

  Supports tap-changing (variable `tap_ratio`) and phase-shifting
  (`phase_shift_deg`) transformers. Impedance values are in per-unit
  on the system base MVA.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "transformers" do
    field :rated_mva, :float
    field :r_pu, :float
    field :x_pu, :float
    field :tap_ratio, :float, default: 1.0
    field :phase_shift_deg, :float, default: 0.0
    field :status, :string, default: "in_service"

    belongs_to :from_bus, PowerModel.Grid.Bus
    belongs_to :to_bus, PowerModel.Grid.Bus

    timestamps()
  end

  def changeset(transformer, attrs) do
    transformer
    |> cast(attrs, [
      :rated_mva,
      :r_pu,
      :x_pu,
      :tap_ratio,
      :phase_shift_deg,
      :status,
      :from_bus_id,
      :to_bus_id
    ])
    |> validate_required([:rated_mva, :x_pu, :from_bus_id, :to_bus_id])
    |> foreign_key_constraint(:from_bus_id)
    |> foreign_key_constraint(:to_bus_id)
  end
end
