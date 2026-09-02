defmodule PowerModel.Repo.Migrations.RepointGeneratorsByGridVoltage do
  use Ecto.Migration

  @moduledoc """
  Backfill EIA-860 grid voltage and re-place the plants it convicts
  (REVIEW CAS-32). 184 GW of in-service capacity sat at least a full voltage
  class below its recorded interconnection voltage — the bus mapper attached
  plants to a yard's lowest level, which the measured dispatch (EXT-4) turned
  into real MW through phantom transformers (1.75 GW of Colorado Bend CCGT on
  a dead-end 69 kV bus). The placement floor now takes the recorded grid
  voltage as evidence; `remap_stranded_generators/1` moves only plants whose
  current bus fails the floor AND for which a strictly better bus exists.
  Both capacity passes then re-derive. NOTE: the plant file
  (`data/2___Plant_Y2024.csv`) is a DOWNLOADED input, not committed — on a
  checkout without the EIA-860 download this migration is a silent no-op (as
  on an empty database), and the backfill and re-map then belong to the
  ingest that follows the download.
  """

  def up do
    case PowerModel.Ingestion.EIA.Form860.backfill_grid_voltage() do
      {:error, :no_plant_file} ->
        :ok

      {plants, generators} ->
        IO.puts("grid voltage backfilled: #{plants} plants, #{generators} generators")

        report = PowerModel.Ingestion.BusMapper.remap_stranded_generators()

        IO.puts(
          "remap: #{report.plants} plants moved (#{report.generators} generators, " <>
            "#{Float.round(report.moved_mw / 1000.0, 1)} GW of #{report.examined} plants examined)"
        )

        PowerModel.Ingestion.CapacityInference.run()
        opts = [alpha_steps: [0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 1.0], target: 1.0]
        PowerModel.Ingestion.CapacityInference.run_ceiling(opts)
    end
  end

  def down do
    # The moves are not tracked row by row; re-running the mapper against the
    # same evidence is idempotent, so down only clears the backfilled column
    # and unfolds inferred circuits the way 20260901130000's down does.
    execute "update generators set grid_voltage_kv = null"

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
