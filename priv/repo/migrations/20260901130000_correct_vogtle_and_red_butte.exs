defmodule PowerModel.Repo.Migrations.CorrectVogtleAndRedButte do
  use Ecto.Migration

  @moduledoc """
  Two refused corridors whose missing capacity is a station the model carries
  as untied HIFLD records (REVIEW CAS-30): Plant Vogtle's two 500 kV yards,
  0.6 km apart with no branch between them, and Red Butte's 345/138 kV yard
  whose 138 kV half is a separate record while the transformer lands on a
  dead-end bus HIFLD calls 115 kV. OSM evidence and prior values are in
  `data/vendored/osm_corridor_corrections_2026-09-01.json`.

  DATA migration: the two corrections, then the capacity passes re-run from
  scratch (`CapacityInference.run/0` unfolds every stored count first, so the
  circuits inferred around these sites are re-derived against the corrected
  network) and the pocket loop on top. Down removes the inserted lines,
  restores the reclassed rows, and unfolds the circuits.
  """

  import Ecto.Query
  alias PowerModel.Repo

  def up do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # --- Vogtle: tie the 500 kV yards.
    tie(
      "37107_500.0kV",
      "40786_500.0kV",
      500.0,
      0.65,
      "osm_way_863571818_vogtle_500kV_tie",
      now
    )

    # --- Red Butte: the "115 kV" bus and its line are the 138 kV yard.
    execute """
    update buses set base_kv = 138.0 where source_id = '58560_115.0kV' and base_kv = 115.0
    """

    execute """
    update transmission_lines set voltage_kv = 138.0, voltage_source = 'osm_corridor'
     where source_id = '204330' and voltage_kv = 115.0
    """

    tie(
      "58560_115.0kV",
      "63596_138.0kV",
      138.0,
      0.13,
      "osm_way_88146572_red_butte_138kV_weld",
      now
    )

    PowerModel.Ingestion.CapacityInference.run()
    opts = [alpha_steps: [0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 1.0], target: 1.0]
    PowerModel.Ingestion.CapacityInference.run_ceiling(opts)
  end

  def down do
    execute "delete from transmission_lines where source_id in ('osm_way_863571818_vogtle_500kV_tie','osm_way_88146572_red_butte_138kV_weld')"

    execute "update transmission_lines set voltage_kv = 115.0, voltage_source = null where source_id = '204330'"

    execute "update buses set base_kv = 115.0 where source_id = '58560_115.0kV'"

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

  # A no-op on a database without these yards (a fresh checkout's test DB):
  # the correction is to the ingested network, not a schema change.
  defp tie(from_sid, to_sid, kv, km, source_id, now) do
    from_ids = Repo.all(from(b in "buses", where: b.source_id == ^from_sid, select: b.id))
    to_ids = Repo.all(from(b in "buses", where: b.source_id == ^to_sid, select: b.id))

    case {from_ids, to_ids} do
      {[from_id], [to_id]} -> insert_tie(from_id, to_id, kv, km, source_id, now)
      _ -> :skipped
    end
  end

  defp insert_tie(from_id, to_id, kv, km, source_id, now) do
    attrs = %{voltage_kv: kv, length_km: km, geometry: nil, from_bus: nil, to_bus: nil}
    p = PowerModel.Ingestion.ParameterEstimator.line_params(attrs)

    Repo.insert_all("transmission_lines", [
      %{
        from_bus_id: from_id,
        to_bus_id: to_id,
        voltage_kv: kv,
        r_pu: p.r_pu,
        x_pu: p.x_pu,
        b_pu: p.b_pu,
        rating_a_mva: p.rating_a_mva,
        rating_b_mva: p.rating_b_mva,
        rating_c_mva: p.rating_c_mva,
        length_km: km,
        status: "in_service",
        source: "osm_corridor",
        source_id: source_id,
        voltage_source: "osm_corridor",
        inferred_circuits: 1,
        params_version: p.params_version,
        inserted_at: now,
        updated_at: now
      }
    ])
  end
end
