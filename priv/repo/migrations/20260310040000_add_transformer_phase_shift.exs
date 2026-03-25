defmodule PowerModel.Repo.Migrations.AddTransformerPhaseShift do
  use Ecto.Migration

  def change do
    alter table(:transformers) do
      add :phase_shift_deg, :float, default: 0.0
    end
  end
end
