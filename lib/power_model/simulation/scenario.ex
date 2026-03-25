defmodule PowerModel.Simulation.Scenario do
  @moduledoc """
  Persisted simulation scenario defining initial conditions and failure injections.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "simulation_scenarios" do
    field :name, :string
    field :base_mva, :float, default: 100.0
    field :solver_config, :map, default: %{}
    field :status, :string, default: "pending"

    belongs_to :interconnection, PowerModel.Grid.Interconnection

    has_many :results, PowerModel.Simulation.Result
    has_many :failure_events, PowerModel.Simulation.FailureEvent

    timestamps()
  end

  def changeset(scenario, attrs) do
    scenario
    |> cast(attrs, [:name, :base_mva, :solver_config, :status, :interconnection_id])
    |> validate_required([:name])
    |> validate_inclusion(:status, ~w(pending running converged diverged error))
  end
end
