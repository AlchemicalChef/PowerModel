defmodule PowerModel.Repo.Migrations.AddTransformerParamsVersion do
  use Ecto.Migration

  @moduledoc """
  ROADMAP item 8 (recompute-not-fill-NULL) for the transformer side.

  Writers stamp their module's `@params_version`; a re-map pass revisits every
  row stamped below the current version instead of the fill-only behaviour
  that made stored parameters permanently uncorrectable. Existing rows default
  to 0, which is below every published version, so they are all stale on the
  first re-map.
  """

  def change do
    alter table(:transformers) do
      add :params_version, :integer, default: 0, null: false
    end

    create index(:transformers, [:params_version])
  end
end
