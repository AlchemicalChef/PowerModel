defmodule PowerModel.Repo.Migrations.ReallocateCountyLoadCapacityAware do
  use Ecto.Migration

  @moduledoc """
  Re-spreads the synthetic load baseline under the capacity-aware rule (TOPO-2,
  TOPO-6, LIN13-B load half).

  The old rule split each county's population over the 25 PQ buses nearest its
  centroid, inverse-distance weighted with a 1 km floor and no idea of voltage,
  yard structure or branch capacity. It produced load no network can serve:
  Harris County's 5.0 M people reached RITTENHOUSE at 1.5 km and put 1,530.83 MW
  on EACH of its two buses; SCE's GALE and HARVARD held their county share once
  per voltage level and left 1,030 MW behind a 55.6 MVA 33 kV line, which is the
  Western interconnection's last branch needing more than 90 degrees; 2.2 GW of
  ERCOT load sat on buses with no branch at all.

  This is a DATA migration: it calls `LoadEstimator.reallocate/0`, which applies
  exactly the rule `LoadEstimator.run/0` now applies to a fresh estimate, over
  the EXISTING baseline total rather than recomputing it from generation
  capacity. Holding the total fixed makes the change purely spatial, so per-BA
  share drift and degree-1 load share move only because load moved.

  It then re-runs `BusMapper.resize_transformers_to_through_load/0`. DR-4's
  resize sizes a bank from the load standing behind it, so on a database it has
  already run, bank ratings encode the misplacement — HARVARD's 66 kV bank reads
  800 MVA precisely because 300 MW was parked behind it. The allocator therefore
  caps against the CLASS-STANDARD bank rating, and this pass takes the stored
  ratings back down to what the corrected load justifies. The two agree by
  construction afterwards: the cap is `0.8 x unit` and the resize buys
  `ceil(load / 0.8 / unit)` units.

  Census before and after:

      mix grid.census load_placement
      mix grid.census stranding --graph main-island
  """

  def up do
    before = census()

    case PowerModel.Ingestion.LoadEstimator.reallocate() do
      # An un-ingested database (a fresh test schema) has nothing to place.
      {:error, :no_buses} ->
        IO.puts("No load-serving buses; nothing to reallocate.")

      {:ok, summary} ->
        IO.puts(
          "Load reallocated: #{Float.round(summary.moved_mw, 1)} MW moved across " <>
            "#{summary.buses_before} -> #{summary.buses_after} load buses " <>
            "(#{summary.gained} gained, #{summary.lost} lost, #{summary.emptied} emptied); " <>
            "#{summary.capped_buses} at their capability cap, " <>
            "#{Float.round(summary.residual_mw, 1)} MW unplaceable"
        )

        resize = PowerModel.Ingestion.BusMapper.resize_transformers_to_through_load()

        IO.puts(
          "Banks re-sized to the corrected through-load: #{resize.resized} transformers, " <>
            "#{Float.round(resize.added_mva / 1000.0, 1)} GVA net"
        )

        print_census(before, census())
    end
  end

  def down do
    # No reverse: the pre-migration p_mw was the output of the old KNN-25 rule,
    # not a recorded value. `mix power_model.ingest estimate_loads` rebuilds the
    # baseline from scratch under the current rule.
    :ok
  end

  # The all-components, unscaled-baseline view of the four rules, in SQL so the
  # gate costs a second rather than three main-island snapshots. The hour-scaled
  # main-island census the acceptance table is written from is
  # `mix grid.census load_placement`.
  defp census do
    %{rows: [row]} =
      repo().query!(
        """
        WITH branch AS (
          SELECT from_bus_id AS bus_id, COALESCE(rating_a_mva, 0.0) AS mva
            FROM transmission_lines WHERE status = 'in_service'
              AND from_bus_id IS NOT NULL AND to_bus_id IS NOT NULL
          UNION ALL
          SELECT to_bus_id, COALESCE(rating_a_mva, 0.0)
            FROM transmission_lines WHERE status = 'in_service'
              AND from_bus_id IS NOT NULL AND to_bus_id IS NOT NULL
          UNION ALL
          SELECT from_bus_id, COALESCE(rated_mva, 0.0)
            FROM transformers WHERE status = 'in_service'
              AND from_bus_id IS NOT NULL AND to_bus_id IS NOT NULL
          UNION ALL
          SELECT to_bus_id, COALESCE(rated_mva, 0.0)
            FROM transformers WHERE status = 'in_service'
              AND from_bus_id IS NOT NULL AND to_bus_id IS NOT NULL
        ),
        cap AS (
          SELECT bus_id, SUM(mva) AS mva, COUNT(*) AS degree
          FROM branch WHERE bus_id IS NOT NULL GROUP BY bus_id
        ),
        bus_load AS (
          SELECT b.id, b.base_kv, b.source_id, SUM(l.p_mw) AS mw,
                 COALESCE(cap.mva, 0.0) AS mva, COALESCE(cap.degree, 0) AS degree
          FROM loads l
          JOIN buses b ON b.id = l.bus_id
          LEFT JOIN cap ON cap.bus_id = b.id
          WHERE l.status = 'in_service' AND l.load_type = 'constant_power'
          GROUP BY b.id, b.base_kv, b.source_id, cap.mva, cap.degree
        )
        SELECT
          COUNT(*) FILTER (WHERE degree = 0 AND mw > 0.0),
          ROUND(COALESCE(SUM(mw) FILTER (WHERE degree = 0), 0.0)::numeric, 1),
          COUNT(*) FILTER (WHERE degree = 1 AND mw > mva),
          COUNT(*) FILTER (WHERE base_kv < 60.0 AND mw > 0.0),
          ROUND(COALESCE(SUM(mw) FILTER (WHERE base_kv < 60.0), 0.0)::numeric, 1),
          (SELECT COUNT(*) FROM (
             SELECT split_part(source_id, '_', 1) AS yard
             FROM bus_load WHERE mw > 0.0 AND source_id IS NOT NULL
             GROUP BY 1 HAVING COUNT(*) > 1
           ) split),
          COUNT(*),
          ROUND(COALESCE(SUM(mw), 0.0)::numeric, 1)
        FROM bus_load
        """,
        [],
        timeout: :infinity
      )

    [unservable, unservable_mw, over_rating, sub_floor, sub_floor_mw, split, buses, mw] = row

    %{
      unservable: unservable,
      unservable_mw: unservable_mw,
      over_rating: over_rating,
      sub_floor: sub_floor,
      sub_floor_mw: sub_floor_mw,
      split_yards: split,
      buses: buses,
      mw: mw
    }
  end

  defp print_census(before, aft) do
    IO.puts("Load placement (all components, unscaled baseline):")

    for {label, key} <- [
          {"load buses", :buses},
          {"baseline MW", :mw},
          {"unservable buses (degree 0)", :unservable},
          {"unservable MW", :unservable_mw},
          {"degree-1 buses over their branch's rating", :over_rating},
          {"buses below the 60 kV load-serving floor", :sub_floor},
          {"MW below the 60 kV floor", :sub_floor_mw},
          {"yards holding load on more than one level", :split_yards}
        ] do
      IO.puts("  #{label}: #{Map.fetch!(before, key)} -> #{Map.fetch!(aft, key)}")
    end
  end
end
