defmodule PowerModel.Simulation.Result do
  use Ecto.Schema
  import Ecto.Changeset

  schema "simulation_results" do
    field :vm_pu, :float
    field :va_rad, :float
    field :p_gen_mw, :float
    field :q_gen_mvar, :float
    field :p_load_mw, :float
    field :q_load_mvar, :float

    belongs_to :scenario, PowerModel.Simulation.Scenario
    belongs_to :bus, PowerModel.Grid.Bus

    timestamps()
  end

  def changeset(result, attrs) do
    result
    |> cast(attrs, [:vm_pu, :va_rad, :p_gen_mw, :q_gen_mvar,
                     :p_load_mw, :q_load_mvar, :scenario_id, :bus_id])
    |> validate_required([:scenario_id, :bus_id])
    |> foreign_key_constraint(:scenario_id)
    |> foreign_key_constraint(:bus_id)
  end
end
