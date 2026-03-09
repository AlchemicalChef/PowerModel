defmodule PowerModel.Repo.Migrations.AddGeneratorDynamics do
  use Ecto.Migration

  def change do
    alter table(:generators) do
      add :inertia_h, :float
      add :droop_pct, :float
      add :gov_time_constant_s, :float
      add :ramp_rate_mw_per_min, :float
      add :marginal_cost_per_mwh, :float
      add :v_set_pu, :float, default: 1.0
      add :agc_participation_factor, :float, default: 0.0
    end
  end
end
