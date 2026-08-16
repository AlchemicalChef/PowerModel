defmodule PowerModel.Repo.Migrations.RetirePdciPhantomLevels do
  use Ecto.Migration

  @moduledoc """
  Removes the phantom 1000 kV yard levels, buses and transformers the Pacific
  DC Intertie seeded (LIN-12).

  HIFLD stores an HVDC bipole's POLE-TO-POLE rating in the same VOLTAGE field
  it stores AC line voltages in, so the PDCI (`transmission_lines` source_id
  200823, CELILO -> SYLMAR EAST, a +/-500 kV link) reads as a 1000 kV line.
  `grid.ex` correctly keeps it out of every AC snapshot and `dc_ties` id 1
  carries its real 3,100 MW schedule, but
  `Substations.augment_voltage_levels_from_lines/0` had no such filter and
  merged 1000 kV into CELILO (58039) and SYLMAR EAST (70910). `BusMapper`
  then gave each yard a 1000 kV bus (87181, 89094) and built a placeholder
  transformer to reach it (7527: 1000->500, 6146: 1000->230, x = 0.01), and
  those stubs DO enter every Western snapshot, where `mix grid.accuracy`
  censuses them as a "765 kV+" voltage class that does not exist anywhere in
  North America.

  The ingester no longer seeds the level. This clears what it already seeded:

    1. the above-765 kV levels stored on the two yards — left in place they
       would rebuild the buses and transformers on the next
       `BusMapper.remap/0`;
    2. every transformer with an above-765 kV endpoint, retired BY STATUS
       rather than deleted, per project convention.

  Buses carry no status column, and none is needed: a bus reaches a snapshot
  only through an in-service branch (`Grid.get_grid_snapshot/2` takes the
  largest connected component of the in-service lines and transformers), and
  the only other branch on either phantom bus is the DC line itself, which
  `in_service_lines/1` already excludes. Retiring the transformer therefore
  drops the bus from the Western snapshot — the measured effect is exactly
  two buses — while leaving the row for the DC line to keep pointing at.

  Written as PREDICATES rather than the four dev-database ids so it is a
  no-op, not a mis-hit, on any database whose ids differ.
  """

  @max_ac_kv 765.0

  def up do
    phantom_buses = query_rows("SELECT id, base_kv FROM buses WHERE base_kv > #{@max_ac_kv}")

    yards =
      query_rows("""
      SELECT id, name FROM substations
      WHERE EXISTS (SELECT 1 FROM unnest(voltage_levels) AS v WHERE v > #{@max_ac_kv})
      """)

    transformers =
      query_rows("""
      SELECT DISTINCT t.id, t.from_bus_id, t.to_bus_id
      FROM transformers t
      JOIN buses b ON b.id = t.from_bus_id OR b.id = t.to_bus_id
      WHERE b.base_kv > #{@max_ac_kv} AND t.status = 'in_service'
      """)

    execute("""
    UPDATE substations s
    SET voltage_levels = k.levels,
        max_voltage_kv = k.levels[1],
        min_voltage_kv = CASE
                           WHEN array_length(k.levels, 1) > 1
                           THEN k.levels[array_length(k.levels, 1)]
                         END,
        updated_at = now()
    FROM (
      SELECT s2.id,
             ARRAY(
               SELECT v FROM unnest(s2.voltage_levels) AS v
               WHERE v <= #{@max_ac_kv} ORDER BY v DESC
             ) AS levels
      FROM substations s2
      WHERE EXISTS (SELECT 1 FROM unnest(s2.voltage_levels) AS v WHERE v > #{@max_ac_kv})
    ) k
    WHERE s.id = k.id
    """)

    execute("""
    UPDATE transformers t
    SET status = 'out_of_service', updated_at = now()
    FROM buses b
    WHERE (t.from_bus_id = b.id OR t.to_bus_id = b.id)
      AND b.base_kv > #{@max_ac_kv}
      AND t.status = 'in_service'
    """)

    IO.puts(
      "LIN-12 PDCI phantoms: #{length(yards)} yards stripped of an above-#{trunc(@max_ac_kv)} kV " <>
        "level #{inspect(yards)}, #{length(transformers)} transformers retired " <>
        "#{inspect(transformers)}, #{length(phantom_buses)} buses left without an AC branch " <>
        "#{inspect(phantom_buses)}"
    )
  end

  def down do
    # The phantom buses are still there, and their base_kv and source_id
    # ("<substation_id>_1000.0kV") are what the level and the transformer were
    # built from, so both are reconstructible.
    execute("""
    UPDATE transformers t
    SET status = 'in_service', updated_at = now()
    FROM buses b
    WHERE (t.from_bus_id = b.id OR t.to_bus_id = b.id)
      AND b.base_kv > #{@max_ac_kv}
      AND t.status = 'out_of_service'
    """)

    execute("""
    UPDATE substations s
    SET voltage_levels = k.levels,
        max_voltage_kv = k.levels[1],
        min_voltage_kv = CASE
                           WHEN array_length(k.levels, 1) > 1
                           THEN k.levels[array_length(k.levels, 1)]
                         END,
        updated_at = now()
    FROM (
      SELECT split_part(b.source_id, '_', 1)::bigint AS id,
             ARRAY(
               SELECT DISTINCT v FROM unnest(
                 s2.voltage_levels || ARRAY[b.base_kv]::float8[]
               ) AS v ORDER BY v DESC
             ) AS levels
      FROM buses b
      JOIN substations s2 ON s2.id = split_part(b.source_id, '_', 1)::bigint
      WHERE b.base_kv > #{@max_ac_kv} AND b.source = 'substation'
    ) k
    WHERE s.id = k.id
    """)
  end

  defp query_rows(sql) do
    %{rows: rows} = repo().query!(sql, [], log: false)
    Enum.map(rows, &List.to_tuple/1)
  end
end
