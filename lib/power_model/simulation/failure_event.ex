defmodule PowerModel.Simulation.FailureEvent do
  @moduledoc """
  Individual failure event within a cascade simulation (trip, shed, or relay action).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "failure_events" do
    field :step, :integer
    field :component_type, :string
    field :component_id, :integer
    field :failure_cause, :string
    field :details, :map, default: %{}

    belongs_to :scenario, PowerModel.Simulation.Scenario

    timestamps()
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:step, :component_type, :component_id, :failure_cause, :details, :scenario_id])
    |> validate_required([:step, :component_type, :component_id, :failure_cause, :scenario_id])
    |> validate_inclusion(:component_type, ~w(transmission_line generator transformer load bus))
    |> foreign_key_constraint(:scenario_id)
  end
end
