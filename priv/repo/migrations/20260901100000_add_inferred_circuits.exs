defmodule PowerModel.Repo.Migrations.AddInferredCircuits do
  use Ecto.Migration

  @moduledoc """
  Per-branch count of parallel circuits inferred from at-rest loading
  (`PowerModel.Ingestion.CapacityInference`, REVIEW CAS-30). The factor is
  folded into the stored r/x/b and ratings; the column is the provenance that
  says how much of a branch's capacity is inferred rather than ingested, and
  what the pass has to unfold before it re-runs.
  """

  def change do
    alter table(:transmission_lines) do
      add :inferred_circuits, :integer, null: false, default: 1
    end

    alter table(:transformers) do
      add :inferred_circuits, :integer, null: false, default: 1
    end
  end
end
