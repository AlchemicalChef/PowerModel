defmodule PowerModel.Repo.Migrations.RebaseTransformerImpedancesToRatedMva do
  use Ecto.Migration

  @moduledoc """
  LIN-3: transformer impedances were stored as a fixed x_pu = 0.10 /
  r_pu = 0.003 on the 100 MVA SYSTEM base regardless of the bank's rating.
  A typical transformer has ~10% impedance on its OWN MVA base, so a
  500 MVA bank should carry x_pu = 0.10 * (100 / 500) = 0.02 on the system
  base — the fixed value made large banks 2-10x too impedant.

  Rebase existing rows from their rated_mva. Only rows still carrying the
  legacy default (x_pu = 0.1) are touched, which makes the rebase idempotent
  and leaves any hand-curated impedances alone.
  """

  def up do
    execute """
    UPDATE transformers
    SET x_pu = 0.10 * (100.0 / rated_mva),
        r_pu = 0.003 * (100.0 / rated_mva)
    WHERE rated_mva IS NOT NULL
      AND rated_mva > 0
      AND x_pu = 0.1
    """
  end

  def down do
    # Restore the legacy fixed system-base values for rows this migration
    # rebased (identified by exactly matching the rebased formula).
    execute """
    UPDATE transformers
    SET x_pu = 0.1,
        r_pu = 0.003
    WHERE rated_mva IS NOT NULL
      AND rated_mva > 0
      AND abs(x_pu - 0.10 * (100.0 / rated_mva)) < 1.0e-12
    """
  end
end
