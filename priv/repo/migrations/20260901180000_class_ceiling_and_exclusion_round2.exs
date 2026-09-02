defmodule PowerModel.Repo.Migrations.ClassCeilingAndExclusionRound2 do
  use Ecto.Migration

  @moduledoc """
  Two closures in one re-derivation (REVIEW CAS-33). First, the class
  CEILING: CAS-32's floor only pushed plants UP, and 302 plants / 121.6 GW
  sat a full class ABOVE their EIA-860-recorded interconnection with an
  in-class bus within 3 km — injection attributed at EHV that really enters
  at subtransmission, softening exactly the stress the congestion score
  measures. `plant_voltage_band/2` now bounds placement from both sides and
  the re-map moves an above-class plant down only onto an in-class bus that
  can evacuate its nameplate. Second, round 2 of the exclusion loop: the
  geocoder's station source found 6 more MISO binding elements, 2 of them
  already "fixed" with inferred circuits, so the freshly emitted
  `known_binding_elements_2026-09-01_r2.csv` joins the glob before the
  passes re-run (at the measured operating point with re-dispatch before
  inference — the defaults since CAS-32). No-op on an empty database.
  """

  def up do
    report = PowerModel.Ingestion.BusMapper.remap_stranded_generators()

    IO.puts(
      "ceiling remap: #{report.plants} plants (#{report.generators} generators, " <>
        "#{Float.round(report.moved_mw / 1000.0, 1)} GW of #{report.examined} examined)"
    )

    PowerModel.Ingestion.CapacityInference.run()
    opts = [alpha_steps: [0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 1.0], target: 1.0]
    PowerModel.Ingestion.CapacityInference.run_ceiling(opts)
  end

  def down do
    # Down-moves are not tracked row by row (the re-map against the same
    # evidence is idempotent); down only unfolds inferred circuits the way
    # 20260901130000's down does, so a re-run starts clean.
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
