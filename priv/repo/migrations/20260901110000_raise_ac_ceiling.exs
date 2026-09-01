defmodule PowerModel.Repo.Migrations.RaiseAcCeiling do
  use Ecto.Migration

  @moduledoc """
  The pockets the at-rest capacity pass cannot see (REVIEW CAS-30, second
  rule): load areas whose feed is too WEAK rather than too small — fine on MVA
  loading, past their P-V nose on reactance — found from where the controlled
  AC solve collapses, their feeding path traced from the DC flow, and the path
  reinforced until the load it carries is inside the radial loadability
  criterion.

  Measured in memory 2026-09-01 before this ran: Western's controlled ceiling
  0.49 → 0.9 through 30 pocket fixes (459 extra circuits on 93 branches, paths
  at 33-138 kV); what remains at α 1.0 are 360-1,050 MW regions behind 69/115
  kV paths already at the 8-circuit cap — misplaced load or missing EHV
  corridors, which this pass refuses by design. Eastern: no pocket-shaped
  failure left (0 fixes). ERCOT already solves at α 1.0.

  DATA migration: calls `CapacityInference.run_ceiling/1` at the latest
  ingested hour. Adds circuits only where the AC solve still fails, on top of
  what `inferred_circuits` already records; undo is the same unfold as
  20260901100001's.
  """

  def up do
    opts = [alpha_steps: [0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 1.0], target: 1.0]
    PowerModel.Ingestion.CapacityInference.run_ceiling(opts)
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
