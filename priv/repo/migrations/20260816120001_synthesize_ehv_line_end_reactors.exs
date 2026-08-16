defmodule PowerModel.Repo.Migrations.SynthesizeEhvLineEndReactors do
  use Ecto.Migration

  @moduledoc """
  Puts shunt reactors on the EHV buses that had none (LIN13-C).

  The network models line charging correctly — per-km susceptance matches
  published typicals to three digits at every voltage class — but modeled no
  compensation at all: `bs_mvar` was 0.0 on all 89,969 buses, and `gs_mw` too.
  Western alone therefore injects 44.3 GVAr of uncompensated charging into a
  network whose only reactive sinks are generator `q_min`, which is why its
  light-load AC solutions push thousands of buses above 1.1 pu. Real EHV
  systems absorb roughly half their charging in line-end reactors.

  This is a DATA migration, not a schema one: it calls
  `ParameterEstimator.synthesize_line_end_reactors/1`, which is the same pass a
  re-ingest runs, so the migrated database and a freshly ingested one hold the
  same reactors rather than two implementations that can drift. The pass writes
  absolute values (it does not accumulate) and owns only negative `bs_mvar`, so
  running it twice is a no-op and capacitor banks are never touched.

  DC solutions are unaffected, provably: DC power flow never reads `bs_mvar`.
  """

  def up do
    summary = PowerModel.Ingestion.ParameterEstimator.synthesize_line_end_reactors()

    IO.puts(
      "EHV line-end reactors: #{summary.buses} buses across #{summary.lines} lines, " <>
        "#{Float.round(summary.mvar, 1)} MVAr total (#{summary.written} rows written, " <>
        "#{summary.cleared} stale cleared)"
    )
  end

  def down do
    execute("UPDATE buses SET bs_mvar = 0.0, updated_at = now() WHERE bs_mvar < 0.0")
  end
end
