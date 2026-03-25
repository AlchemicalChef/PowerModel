defmodule PowerModel.Grid.Load do
  @moduledoc """
  Electrical load connected to a bus.

  Load type determines ZIP model coefficients used by the AC power flow
  solver for voltage-dependent load behavior.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "loads" do
    field :p_mw, :float
    field :q_mvar, :float
    field :load_type, :string, default: "constant_power"
    field :status, :string, default: "in_service"

    belongs_to :bus, PowerModel.Grid.Bus

    timestamps()
  end

  def changeset(load, attrs) do
    load
    |> cast(attrs, [:p_mw, :q_mvar, :load_type, :status, :bus_id])
    |> validate_required([:p_mw, :bus_id])
    |> foreign_key_constraint(:bus_id)
  end
end
