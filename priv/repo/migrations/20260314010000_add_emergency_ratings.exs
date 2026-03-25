defmodule PowerModel.Repo.Migrations.AddEmergencyRatings do
  use Ecto.Migration

  def change do
    alter table(:transmission_lines) do
      add :rating_b_mva, :float
      add :rating_c_mva, :float
    end
  end
end
