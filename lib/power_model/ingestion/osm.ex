defmodule PowerModel.Ingestion.OSM do
  @moduledoc """
  Coordinator for the OSM voltage backfill (ROADMAP item 24, substation wave).

  Runs, in order, against the vendored OSM snapshots (ODbL — see
  `data/vendored/PROVENANCE.md` and the separable-table architecture in the
  migration and `PowerModel.Ingestion.OSM.SubstationMatch`):

    1. `Matcher` — voltage-blind/echo yards vs OSM substations (<= 250 m).
    2. `LineVoltages` — unmatched yards vs OSM power lines passing the yard
       (only when the line snapshot has been fetched; otherwise the pass
       writes the unmatched-yard CSV the fetch script needs and skips).
    3. `RestoredCircuits` — re-derive the TOPO-1 restored circuits' class
       from the OSM-backed yard levels, stamping `params_version: 0`.

  Pipeline position: after `map_buses` (yards, lines, and buses must exist),
  before any `estimate_parameters` re-run (which re-prices the version-0
  rows). Ordering with `augment_voltage_levels_from_lines/0` is enforced in
  code, not here: augmentation skips `voltage_source = osm%` rows.

  With `apply: false` (the default) nothing is written; the returned map is
  the full dry-run report. With `apply: true` an audit of every changed row
  (old values included) is written to `:audit_path` for reversibility.
  """

  alias PowerModel.Ingestion.HIFLD.Names
  alias PowerModel.Ingestion.OSM.{LineVoltages, Matcher, RestoredCircuits}
  alias PowerModel.Ingestion.OSM.Substations, as: OSMSubstations

  @default_snapshot "data/vendored/osm_substations_2026-08-18.json"
  @default_line_snapshot "data/vendored/osm_line_voltages_2026-08-18.json"

  def default_snapshot, do: @default_snapshot
  def default_line_snapshot, do: @default_line_snapshot

  @doc """
  Options:

    * `:apply` — write (default false: dry run).
    * `:snapshot` — OSM substation snapshot path (default `#{@default_snapshot}`).
    * `:line_snapshot` — OSM way snapshot path (default `#{@default_line_snapshot}`);
      skipped with a note when the file does not exist.
    * `:unmatched_csv` — where to write the unmatched-yard list the line
      fetch needs (default `tmp/osm_unmatched_yards.csv`).
    * `:audit_path` — audit JSON destination when applying
      (default `tmp/osm_voltage_audit_<utc timestamp>.json`).
  """
  def run(opts \\ []) do
    apply? = Keyword.get(opts, :apply, false)
    snapshot = Keyword.get(opts, :snapshot, @default_snapshot)
    line_snapshot = Keyword.get(opts, :line_snapshot, @default_line_snapshot)
    unmatched_csv = Keyword.get(opts, :unmatched_csv, "tmp/osm_unmatched_yards.csv")
    snapshot_date = snapshot_date(snapshot)

    IO.puts("OSM voltage backfill (#{if apply?, do: "APPLY", else: "dry run"})")
    IO.puts("  substation snapshot: #{snapshot}")

    eligibility = Matcher.eligible_yards(opts)
    by_class = Enum.frequencies_by(eligibility.eligible, & &1.class)
    IO.puts("  eligible yards: #{length(eligibility.eligible)} #{inspect(by_class)}")

    osm_subs = OSMSubstations.load_snapshot!(snapshot)
    IO.puts("  OSM substations with usable voltage + center: #{length(osm_subs)}")

    %{decisions: decisions, stats: match_stats} = Matcher.match_with(eligibility, osm_subs)
    IO.puts("  matcher: #{inspect(Map.drop(match_stats, [:applied_level_histogram]))}")

    match_result =
      if apply?,
        do: Matcher.apply_decisions(decisions, snapshot_date: snapshot_date),
        else: nil

    unmatched =
      for {:unmatched, yard} <- decisions, do: yard

    line_result = run_line_pass(unmatched, line_snapshot, unmatched_csv, apply?, snapshot_date)

    # The would-be OSM yard levels, so a DRY RUN's re-derivation sees the
    # same evidence an apply run's would (the DB rows exist only after apply).
    extra_entries =
      yard_index_entries(
        for({:applied, yard, cand, _, _, _, _} <- decisions, do: {yard, cand.levels_kv}) ++
          for(
            %{yard: yard, levels: levels} <- (line_result && line_result[:inferences]) || [],
            do: {yard, levels}
          )
      )

    rederive =
      RestoredCircuits.rederive(
        opts
        |> Keyword.put(:apply, apply?)
        |> Keyword.put(:extra_yard_entries, extra_entries)
      )

    IO.puts(
      "  restored circuits: #{rederive.proposals} proposals, " <>
        "#{length(rederive.changeable)} changeable, " <>
        "#{rederive.guarded_externally_corrected} guarded, applied #{rederive.applied}"
    )

    result = %{
      apply: apply?,
      snapshot: snapshot,
      eligible_by_class: by_class,
      match_stats: match_stats,
      match_applied: match_result && Map.drop(match_result, [:audit]),
      line_inference: line_result && Map.drop(line_result, [:audit, :inferences]),
      restored_circuits: Map.drop(rederive, [:changeable]),
      restored_circuit_changes: length(rederive.changeable)
    }

    corridor = if apply?, do: backfill_corridor_markers(opts), else: nil
    if corridor, do: IO.puts("  corridor markers backfilled: #{inspect(corridor)}")

    result = if corridor, do: Map.put(result, :corridor_markers, corridor), else: result

    if apply? do
      audit_path = Keyword.get(opts, :audit_path, default_audit_path())

      write_audit!(audit_path, %{
        substations: (match_result && match_result.audit) || [],
        line_inferred_substations: (line_result && line_result.audit) || [],
        restored_circuits: rederive.changeable
      })

      IO.puts("  audit written: #{audit_path}")
      Map.put(result, :audit_path, audit_path)
    else
      result
    end
  end

  defp run_line_pass(unmatched, line_snapshot, unmatched_csv, apply?, snapshot_date) do
    if File.regular?(line_snapshot) do
      ways = LineVoltages.load_snapshot!(line_snapshot)
      inferences = LineVoltages.infer(unmatched, ways)

      IO.puts(
        "  line inference: #{length(ways)} usable ways, " <>
          "#{length(inferences)}/#{length(unmatched)} unmatched yards get levels"
      )

      if apply? do
        inferences
        |> LineVoltages.apply_inferences(snapshot_date: snapshot_date)
        |> Map.put(:inferences, inferences)
      else
        %{
          applied: length(inferences),
          level_histogram:
            Enum.frequencies_by(inferences, fn i ->
              Enum.map(i.levels, &Float.round(&1, 1))
            end),
          audit: [],
          inferences: inferences
        }
      end
    else
      # The CSV is a fetch input for the NEXT apply run, so writing it on a dry
      # run contradicted this module's own "with apply: false nothing is
      # written" contract and mutated a shared checkout for anyone previewing
      # the pass. Dry runs now say what they WOULD write.
      if apply? do
        write_unmatched_csv!(unmatched_csv, unmatched)

        IO.puts(
          "  line inference SKIPPED: no snapshot at #{line_snapshot}. " <>
            "Wrote #{length(unmatched)} unmatched yards to #{unmatched_csv} — fetch with\n" <>
            "    python3 scripts/fetch_osm_voltage.py lines --yards #{unmatched_csv}"
        )
      else
        IO.puts(
          "  line inference SKIPPED: no snapshot at #{line_snapshot}. " <>
            "#{length(unmatched)} yards are unmatched; re-run with --apply to write " <>
            "#{unmatched_csv} for the fetch step (dry run writes nothing)."
        )
      end

      nil
    end
  end

  @corridor_corrections "data/vendored/osm_corridor_corrections_2026-08-18.json"

  @doc """
  Stamp `voltage_source = "osm_corridor"` on the line rows the corridor wave
  corrected from OSM way evidence (its audit JSON carries the `line_id`s;
  the correction itself was applied by that wave — this only adds the ODbL
  extractability marker). Returns `%{marked: n, rows: n}` or nil when the
  corrections file is absent.
  """
  def backfill_corridor_markers(opts \\ []) do
    path = Keyword.get(opts, :corridor_corrections, @corridor_corrections)

    if File.regular?(path) do
      import Ecto.Query

      ids =
        path
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("rows")
        |> Enum.map(&Map.fetch!(&1, "line_id"))

      {marked, _} =
        from(l in PowerModel.Grid.TransmissionLine,
          where: l.id in ^ids and is_nil(l.voltage_source)
        )
        |> PowerModel.Repo.update_all(set: [voltage_source: "osm_corridor"])

      %{marked: marked, rows: length(ids)}
    else
      nil
    end
  end

  # `%{normalized_name => [{lon, lat, kv}]}` in the yard-voltage-index shape
  # `RestoredCircuits` consumes, from `{yard, levels}` pairs.
  defp yard_index_entries(pairs) do
    Enum.reduce(pairs, %{}, fn {yard, levels}, acc ->
      with true <- Names.identifying?(yard.name),
           normalized when not is_nil(normalized) <- Names.normalize(yard.name) do
        entries = Enum.map(levels, &{yard.lon, yard.lat, &1})
        Map.update(acc, normalized, entries, &(entries ++ &1))
      else
        _ -> acc
      end
    end)
  end

  defp write_unmatched_csv!(path, unmatched) do
    File.mkdir_p!(Path.dirname(path))

    rows =
      Enum.map(unmatched, fn yard ->
        "#{yard.id},#{yard.lat},#{yard.lon}"
      end)

    File.write!(path, Enum.join(["substation_id,lat,lon" | rows], "\n") <> "\n")
  end

  defp write_audit!(path, audit) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(audit, pretty: true))
  end

  defp default_audit_path do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d%H%M%S")
    "tmp/osm_voltage_audit_#{stamp}.json"
  end

  # The fetch date embedded in the snapshot metadata, falling back to the
  # filename convention, so evidence rows record which pull they came from.
  defp snapshot_date(snapshot) do
    with {:ok, raw} <- File.read(snapshot),
         {:ok, %{"metadata" => %{"date_pin" => <<date::binary-size(10), _::binary>>}}} <-
           Jason.decode(raw),
         {:ok, parsed} <- Date.from_iso8601(date) do
      parsed
    else
      _ -> Date.utc_today()
    end
  end
end
