defmodule PowerModel.Repo.Migrations.WeldColocatedYards do
  use Ecto.Migration

  @moduledoc """
  Welds the split yards `repair_connectivity/1` structurally could not reach
  (TOPO-4).

  3,604 pairs of same-level buses sit within 250 m of each other with no
  branch between them, and all but one are already in the SAME component: two
  records of one physical yard, reachable from each other only the long way
  round through the wider network. Every path between them is a false detour
  with a fictitious impedance, and the repair pass could never fix it, because
  it discards any candidate whose union-find roots already match.

  This is a DATA migration: it calls `BusMapper.weld_colocated_buses/1`, the
  same phase a re-ingest now runs inside `repair_connectivity/1`. Joints are
  ordinary `connectivity_repair` lines of the real (very short) distance with
  the parameters of their voltage class, never zero-impedance welds, and the
  phase skips any pair that already carries a direct branch — so running it
  twice adds nothing.

  It cannot merge two interconnections (candidates must share one) and it
  cannot create a self-loop (the pair is two distinct bus ids).
  """

  def up do
    summary = PowerModel.Ingestion.BusMapper.weld_colocated_buses()

    IO.puts(
      "Co-located yard welds: #{summary.welded} joints; components " <>
        "#{summary.components_before} -> #{summary.components_after}"
    )
  end

  def down do
    execute("DELETE FROM transmission_lines WHERE source_id LIKE 'repair\\_weld\\_%'")
  end
end
