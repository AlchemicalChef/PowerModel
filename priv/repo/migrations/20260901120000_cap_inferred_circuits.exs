defmodule PowerModel.Repo.Migrations.CapInferredCircuits do
  use Ecto.Migration

  @moduledoc """
  Brings every branch back inside the 8-circuit cap the capacity passes
  promise (REVIEW CAS-30).

  20260901110000's pocket loop applied the cap to the circuits it added in
  its own run, not to what 20260901100001 had already stored, so four Western
  lines reached 64 inferred circuits and a transformer 24. A 33 kV line with
  64 circuits is exactly what the cap exists to refuse. `raise_ceiling/2` now
  counts stored circuits toward the cap; this migration rescales the rows it
  had already written: x and r multiplied back up by n/8, b and ratings
  divided, `inferred_circuits` set to 8. The pockets behind them become
  refusals, which is the honest answer.
  """

  def up do
    execute """
    update transmission_lines
       set r_pu = r_pu * (inferred_circuits / 8.0), x_pu = x_pu * (inferred_circuits / 8.0),
           b_pu = b_pu / (inferred_circuits / 8.0),
           rating_a_mva = rating_a_mva / (inferred_circuits / 8.0),
           rating_b_mva = rating_b_mva / (inferred_circuits / 8.0),
           rating_c_mva = rating_c_mva / (inferred_circuits / 8.0),
           inferred_circuits = 8
     where inferred_circuits > 8
    """

    execute """
    update transformers
       set r_pu = r_pu * (inferred_circuits / 8.0), x_pu = x_pu * (inferred_circuits / 8.0),
           rated_mva = rated_mva / (inferred_circuits / 8.0),
           inferred_circuits = 8
     where inferred_circuits > 8
    """
  end

  def down do
    :ok
  end
end
