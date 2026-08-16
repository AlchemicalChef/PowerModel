defmodule PowerModel.Simulation.FailureEvent do
  @moduledoc """
  A persisted cascade event.

  `component_type` is validated against the types the live cascade actually
  emits. It had drifted to the five original component tables (CAS-17), which
  would have rejected every event the frequency, voltage and critical-load
  layers produce the first time a scenario was saved:

    * `water_facility` / `datacenter` — a facility that lost power
    * `island` — an island-level event (blackout, solve failure, aggregated
      load shedding); `component_id` is the island's lowest bus id
    * `btm_solar` — a segment's rooftop fleet tripping on frequency or voltage
    * `cascade` — the run itself (e.g. the step budget running out)
  """

  use Ecto.Schema
  import Ecto.Changeset

  @component_types ~w(
    transmission_line generator transformer load bus
    water_facility datacenter island btm_solar cascade
  )

  @doc "Every `component_type` a persisted failure event may carry."
  def component_types, do: @component_types

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
    |> validate_inclusion(:component_type, @component_types)
    |> foreign_key_constraint(:scenario_id)
  end
end
