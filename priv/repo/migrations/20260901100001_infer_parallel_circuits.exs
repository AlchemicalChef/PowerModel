defmodule PowerModel.Repo.Migrations.InferParallelCircuits do
  use Ecto.Migration

  @moduledoc """
  Gives the branches that carry multiples of their rating at rest the parallel
  capacity the real grid must have (REVIEW CAS-26, CAS-30).

  Measured 2026-09-01 at the reference hour, with nothing out of service:
  ERCOT 218 rated branches over 100 % (22,097 MW of overload), Western 135
  (12,030 MW), Eastern 335 (37,989 MW) — 69 kV lines at 300-520 MW on 116 MVA
  ratings, NYC 138 kV circuits at 900 MW. That is why no interconnection has an
  AC solution at real demand: bulk power is being forced through
  subtransmission whose parallel or higher-voltage paths HIFLD does not carry.
  Inferring the circuits from the flow took ERCOT's controlled AC ceiling from
  α 0.6 to 1.0.

  This is a DATA migration: it calls `CapacityInference.run/1`, the same pass a
  re-ingest runs, at the peak and latest ingested demand hours. The pass
  unfolds any previously stored count first, so it is idempotent. Undo unfolds
  everything back to single circuits.
  """

  def up do
    PowerModel.Ingestion.CapacityInference.run()
  end

  def down do
    execute """
    update transmission_lines set r_pu = r_pu * inferred_circuits, x_pu = x_pu * inferred_circuits,
      b_pu = b_pu / inferred_circuits, rating_a_mva = rating_a_mva / inferred_circuits,
      rating_b_mva = rating_b_mva / inferred_circuits, rating_c_mva = rating_c_mva / inferred_circuits,
      inferred_circuits = 1 where inferred_circuits > 1
    """

    execute """
    update transformers set r_pu = r_pu * inferred_circuits, x_pu = x_pu * inferred_circuits,
      rated_mva = rated_mva / inferred_circuits, inferred_circuits = 1 where inferred_circuits > 1
    """
  end
end
