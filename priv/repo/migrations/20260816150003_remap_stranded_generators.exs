defmodule PowerModel.Repo.Migrations.RemapStrandedGenerators do
  use Ecto.Migration

  @moduledoc """
  Moves plants off buses that cannot evacuate them (LIN13-B).

  Grand Coulee's 6,809 MW sat on a 115 kV bus with 537 MVA of connected
  branch, 0.37 km from a 500 kV yard, because generators were mapped to the
  nearest bus at ANY voltage with a tie-break to the yard's LOWEST level. The
  DC solution answered with 180 degrees across the 115 kV corridor out of it,
  and no AC solution exists at that angle. 515 GW of nameplate nationally sits
  on buses whose branches cannot carry 1.2x it.

  This is a DATA migration: it calls
  `BusMapper.remap_stranded_generators/1`, which applies exactly the rule
  `map_generators_to_buses/0` now applies to new rows. It runs LAST of the
  DR-4 migrations because the three before it change branch capacity, which is
  the term the rule ranks on.

  It moves a plant only when the bus it is on cannot carry it AND the bus the
  rule picks is a strict improvement, so a plant already on the best available
  bus stays put and a second run is a no-op. LOADS are never touched, so
  bus->BA demand attribution cannot move.

  Census before applying:

      mix grid.census stranding
  """

  def up do
    before = stranded_nameplate_gw()

    summary = PowerModel.Ingestion.BusMapper.remap_stranded_generators()

    IO.puts(
      "Stranded plants remapped: #{summary.plants} of #{summary.examined} " <>
        "(#{summary.generators} generators, #{Float.round(summary.moved_mw / 1000.0, 1)} GW)"
    )

    IO.puts("Stranded nameplate: #{before} GW -> #{stranded_nameplate_gw()} GW")
  end

  def down do
    # No reverse: the pre-migration bus_id was the output of the old
    # nearest-any-level rule, not a recorded value. `mix power_model.ingest
    # map_buses` after clearing generators.bus_id rebuilds the mapping.
    :ok
  end

  defp stranded_nameplate_gw do
    %{rows: [[gw]]} =
      repo().query!(
        """
        WITH branch AS (
          SELECT from_bus_id AS bus_id, COALESCE(rating_a_mva, 0.0) AS mva
            FROM transmission_lines WHERE status = 'in_service'
          UNION ALL
          SELECT to_bus_id, COALESCE(rating_a_mva, 0.0)
            FROM transmission_lines WHERE status = 'in_service'
          UNION ALL
          SELECT from_bus_id, COALESCE(rated_mva, 0.0)
            FROM transformers WHERE status = 'in_service'
          UNION ALL
          SELECT to_bus_id, COALESCE(rated_mva, 0.0)
            FROM transformers WHERE status = 'in_service'
        ),
        cap AS (SELECT bus_id, SUM(mva) AS mva FROM branch WHERE bus_id IS NOT NULL GROUP BY bus_id),
        gen AS (
          SELECT bus_id, SUM(COALESCE(p_max_mw, 0.0)) AS mw
            FROM generators WHERE status = 'in_service' AND bus_id IS NOT NULL GROUP BY bus_id
        )
        SELECT ROUND((COALESCE(SUM(gen.mw), 0.0) / 1000.0)::numeric, 1)
        FROM gen LEFT JOIN cap ON cap.bus_id = gen.bus_id
        WHERE gen.mw > 1.2 * COALESCE(cap.mva, 0.0)
        """,
        [],
        timeout: :infinity
      )

    gw
  end
end
