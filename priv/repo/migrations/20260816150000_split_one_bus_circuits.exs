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

  def down do
    # The endpoints this filled were NULL and the buses it made are keyed
    # "line_<id>_<side>"; dropping the buses would orphan the lines that now
    # point at them, so the reverse is to unmap those endpoints first.
    execute("""
    UPDATE transmission_lines tl
    SET from_bus_id = CASE WHEN fb.source_id LIKE 'line\\_%' THEN NULL ELSE tl.from_bus_id END,
        to_bus_id   = CASE WHEN tb.source_id LIKE 'line\\_%' THEN NULL ELSE tl.to_bus_id END
    FROM buses fb, buses tb
    WHERE fb.id = tl.from_bus_id AND tb.id = tl.to_bus_id
    """)

    execute("DELETE FROM buses WHERE source = 'synthetic' AND source_id LIKE 'line\\_%'")
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
