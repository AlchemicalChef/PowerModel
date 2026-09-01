defmodule PowerModel.Repo.Migrations.CorrectNorthMccameyAndEagleMountain do
  use Ecto.Migration

  @moduledoc """
  Two ERCOT yard complexes whose 345 kV secondaries HIFLD carries as 69 kV,
  forcing bulk transfer through 69 kV jumpers (REVIEW CAS-31). They surfaced
  as the model's two worst overloads — 560 % and 201 % — the moment measured
  CEMS dispatch put real flow on the network (REVIEW EXT-4): ~2 GW crossing
  North McCamey's yards at 69 kV, ~1.3 GW crossing Eagle Mountain's on a
  synthetic repair weld. OSM shows neither site has a 69 kV level where the
  flow was crossing; evidence and prior values are in
  `data/vendored/osm_corridor_corrections_2026-09-01b.json`.

  No new equipment: the misclassed secondaries become 138 kV (their existing
  345 kV transformers become the real 345/138 banks), the ties are
  re-parameterised at 138 kV and re-pointed to the real 138 kV buses, and
  North McCamey's 69 kV chain hangs off the AEP yard's HIFLD-asserted 138/69
  transformer instead of the LCRA bulk yard. Then both capacity passes
  re-derive, since the circuits inferred around these sites were fitted to
  the wrong topology. No-op on an empty database (every step resolves its
  rows by source_id first).
  """

  import Ecto.Query
  alias PowerModel.Repo

  def up do
    # --- North McCamey: the LCRA yard is 345/138, not 345/69.
    execute "update buses set base_kv = 138.0 where source_id = '67745_69.0kV' and base_kv = 69.0"

    execute "update substations set voltage_levels = '{345,138}', voltage_source = 'osm_corridor' where hifld_id = '301062'"

    reparam("312659", 138.0)
    repoint("312659", :to_bus_id, "67972_138.0kV")
    repoint("305583", :from_bus_id, "67972_69.0kV")

    # --- Eagle Mountain: no 69 kV level exists in the complex at all.
    execute "update buses set base_kv = 138.0 where source_id = '67652_69.0kV' and base_kv = 69.0"

    execute "update substations set voltage_levels = '{345,138}', voltage_source = 'osm_corridor' where hifld_id = '300883'"

    reparam("repair_weld_65735_68115", 138.0)
    repoint("repair_weld_65735_68115", :to_bus_id, "69427_138.0kV")
    reparam("repair_name_65735_71532", 138.0)
    repoint("repair_name_65735_71532", :to_bus_id, "71942_138.0kV")

    PowerModel.Ingestion.CapacityInference.run()
    opts = [alpha_steps: [0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 1.0], target: 1.0]
    PowerModel.Ingestion.CapacityInference.run_ceiling(opts)
  end

  def down do
    execute "update buses set base_kv = 69.0 where source_id = '67745_69.0kV' and base_kv = 138.0"
    execute "update substations set voltage_levels = '{345,69}', voltage_source = null where hifld_id = '301062'"
    execute "update buses set base_kv = 69.0 where source_id = '67652_69.0kV' and base_kv = 138.0"
    execute "update substations set voltage_levels = '{345,69}', voltage_source = null where hifld_id = '300883'"

    reparam("312659", 69.0)
    repoint("312659", :to_bus_id, "67972_69.0kV")
    repoint("305583", :from_bus_id, "67745_69.0kV")
    reparam("repair_weld_65735_68115", 69.0)
    repoint("repair_weld_65735_68115", :to_bus_id, "69427_69.0kV")
    reparam("repair_name_65735_71532", 69.0)
    repoint("repair_name_65735_71532", :to_bus_id, "71942_69.0kV")

    # Circuits were inferred against the corrected topology; unfold them the
    # way 20260901130000's down does, so a re-run starts clean.
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

  # Re-estimate a line's single-circuit parameters at a voltage class, from
  # its stored length. A no-op when the line is absent (fresh test DB).
  defp reparam(source_id, kv) do
    case Repo.all(
           from(l in "transmission_lines",
             where: l.source_id == ^source_id,
             select: {l.id, l.length_km}
           )
         ) do
      [{id, length_km}] ->
        attrs = %{
          voltage_kv: kv,
          length_km: length_km || 0.5,
          geometry: nil,
          from_bus: nil,
          to_bus: nil
        }

        p = PowerModel.Ingestion.ParameterEstimator.line_params(attrs)

        Repo.update_all(
          from(l in "transmission_lines", where: l.id == ^id),
          set: [
            voltage_kv: kv,
            voltage_source: "osm_corridor",
            r_pu: p.r_pu,
            x_pu: p.x_pu,
            b_pu: p.b_pu,
            rating_a_mva: p.rating_a_mva,
            rating_b_mva: p.rating_b_mva,
            rating_c_mva: p.rating_c_mva,
            inferred_circuits: 1,
            params_version: p.params_version
          ]
        )

      _ ->
        :skipped
    end
  end

  # Move one endpoint of a line to the bus a source_id names. A no-op when
  # either side is absent.
  defp repoint(line_source_id, endpoint, bus_source_id) do
    line_ids =
      Repo.all(from(l in "transmission_lines", where: l.source_id == ^line_source_id, select: l.id))

    bus_ids = Repo.all(from(b in "buses", where: b.source_id == ^bus_source_id, select: b.id))

    case {line_ids, bus_ids} do
      {[line_id], [bus_id]} ->
        Repo.update_all(
          from(l in "transmission_lines", where: l.id == ^line_id),
          set: [{endpoint, bus_id}]
        )

      _ ->
        :skipped
    end
  end
end
