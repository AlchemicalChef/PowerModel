defmodule PowerModel.Repo.Migrations.SplitOneBusCircuits do
  use Ecto.Migration

  @moduledoc """
  Recovers circuits the endpoint mapping dropped whole because both of their
  endpoints resolved to one bus (TOPO-5).

  4,563 in-service HIFLD lines had BOTH endpoints NULL, and the largest single
  cause was not a failed match: it was a successful one on both ends. When the
  two endpoints landed on the same bus, `map_transmission_line_buses/0` left
  the circuit fully unmapped rather than create a self-loop, and 3,442
  endpoints that had resolved perfectly well went with it.

  This is a DATA migration: it re-runs `BusMapper.map_transmission_line_buses/0`,
  which is fill-mode — it only ever writes an endpoint that is NULL — so a
  correctly mapped circuit cannot be disturbed. Under the rule it now carries,
  a one-bus circuit whose endpoints are more than 1 km apart in a straight
  line keeps the resolved bus on the near end and re-resolves the far end with
  that bus excluded, creating a bus at the far coordinate only when the
  geometric tiers find nothing. Circuits whose endpoints really are one point
  (intra-yard jumpers) are still skipped, and there is no path in the pass that
  can write `from_bus_id == to_bus_id`.
  """

  def up do
    before = null_endpoint_lines()

    stats = PowerModel.Ingestion.BusMapper.map_transmission_line_buses()

    IO.puts(
      "One-bus circuits: #{Map.get(stats, :same_bus_split, 0)} split against an existing bus, " <>
        "#{Map.get(stats, :same_bus_synthetic, 0)} against a bus created at the far endpoint, " <>
        "#{Map.get(stats, :self_loop_skipped, 0)} left as intra-yard stubs"
    )

    IO.puts("In-service lines with a NULL endpoint: #{before} -> #{null_endpoint_lines()}")
  end

  # The buses this created are keyed "line_<id>_<side>", and dropping one
  # while anything still points at it is a foreign-key violation, so the
  # reverse unmaps every referent first.
  #
  # REVIEW DAT-27: unmapping the LINE endpoints is not enough. Migration
  # 150003 runs after this one and moves plants onto whichever bus can
  # evacuate them, which put 102 generators on 413 of these buses; its own
  # down/0 is `:ok`, so rolling this one back met `generators_bus_id_fkey`
  # (23503) and left the database mid-rollback. Both referents are cleared
  # here, and `mix power_model.ingest map_buses` — a fill pass, so it writes
  # only the NULLs this leaves — rebuilds the mapping, exactly as 150002 and
  # 150003 direct.
  @synthetic_bus_where "source = 'synthetic' AND source_id LIKE 'line\\_%'"

  def down do
    blocked = blocking_referents()

    if blocked != [] do
      raise "Cannot reverse: #{Enum.join(blocked, ", ")} still reference the buses this " <>
              "migration created, and this file cannot null them. Clear them first, or " <>
              "rebuild the whole mapping with `mix power_model.ingest map_buses`."
    end

    # Written one side at a time: a line with a synthetic bus on one end and a
    # NULL on the other has no row to join the second endpoint against, and a
    # two-endpoint join would skip it.
    execute("""
    UPDATE transmission_lines SET from_bus_id = NULL
    WHERE from_bus_id IN (SELECT id FROM buses WHERE #{@synthetic_bus_where})
    """)

    execute("""
    UPDATE transmission_lines SET to_bus_id = NULL
    WHERE to_bus_id IN (SELECT id FROM buses WHERE #{@synthetic_bus_where})
    """)

    execute("""
    UPDATE generators SET bus_id = NULL
    WHERE bus_id IN (SELECT id FROM buses WHERE #{@synthetic_bus_where})
    """)

    execute("DELETE FROM buses WHERE #{@synthetic_bus_where}")
  end

  # Tables whose bus reference this file has no honest way to clear:
  # `simulation_results.bus_id` is NOT NULL, and the rest carry a mapping a
  # different pass owns. Zero rows in the database this was written against —
  # the check is here so a future one fails with a sentence instead of a
  # constraint name halfway through the rollback.
  defp blocking_referents do
    for {table, column} <- [
          {"simulation_results", "bus_id"},
          {"loads", "bus_id"},
          {"btm_solar", "bus_id"},
          {"datacenters", "bus_id"},
          {"water_facilities", "bus_id"},
          {"transformers", "from_bus_id"},
          {"transformers", "to_bus_id"},
          {"dc_ties", "from_bus_id"},
          {"dc_ties", "to_bus_id"}
        ],
        count = referent_count(table, column),
        count > 0,
        do: "#{count} #{table}.#{column}"
  end

  defp referent_count(table, column) do
    %{rows: [[count]]} =
      repo().query!(
        "SELECT COUNT(*) FROM #{table} WHERE #{column} IN " <>
          "(SELECT id FROM buses WHERE #{@synthetic_bus_where})",
        [],
        timeout: :infinity
      )

    count
  end

  defp null_endpoint_lines do
    %{rows: [[count]]} =
      repo().query!(
        "SELECT COUNT(*) FROM transmission_lines WHERE status = 'in_service' " <>
          "AND (from_bus_id IS NULL OR to_bus_id IS NULL)",
        [],
        timeout: :infinity
      )

    count
  end
end
