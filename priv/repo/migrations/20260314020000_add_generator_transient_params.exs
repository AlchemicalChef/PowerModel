defmodule PowerModel.Repo.Migrations.AddGeneratorTransientParams do
  use Ecto.Migration

  def change do
    alter table(:generators) do
      add :x_d_pu, :float
      add :x_d_prime_pu, :float
      add :x_q_pu, :float
      add :x_q_prime_pu, :float
      add :t_d0_prime_s, :float
      add :t_q0_prime_s, :float
      add :ra_pu, :float
      add :d_factor, :float
      add :mva_base, :float
      add :exciter_model, :string
      add :governor_model, :string
    end
  end
end
