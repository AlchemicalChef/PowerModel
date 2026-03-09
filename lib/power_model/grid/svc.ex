defmodule PowerModel.Grid.SVC do
  @moduledoc """
  Schema for Static VAR Compensators (SVCs).

  An SVC is a shunt-connected FACTS device that provides continuous reactive
  power control.  In voltage-control mode it regulates the bus voltage to
  `v_set_pu` within the reactive limits `[q_min_mvar, q_max_mvar]`.  The
  `slope_pct` field defines the droop characteristic (voltage vs. reactive
  output).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "svcs" do
    field :name, :string
    field :q_max_mvar, :float
    field :q_min_mvar, :float
    field :v_set_pu, :float, default: 1.0
    field :control_mode, :string, default: "voltage"
    field :slope_pct, :float, default: 3.0
    field :status, :string, default: "in_service"

    belongs_to :bus, PowerModel.Grid.Bus

    timestamps()
  end

  @cast_fields [
    :name, :q_max_mvar, :q_min_mvar, :v_set_pu,
    :control_mode, :slope_pct, :status, :bus_id
  ]

  def changeset(svc, attrs) do
    svc
    |> cast(attrs, @cast_fields)
    |> validate_required([:q_max_mvar, :q_min_mvar, :bus_id])
    |> validate_inclusion(:control_mode, ["voltage", "fixed_q"])
    |> foreign_key_constraint(:bus_id)
  end
end
