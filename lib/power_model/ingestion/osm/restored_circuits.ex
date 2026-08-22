defmodule PowerModel.Ingestion.OSM.RestoredCircuits do
  @moduledoc """
  Re-derive the TOPO-1 restored circuits' voltage class from the OSM-backed
  yard voltages (ROADMAP item 24's "when OSM voltage lands" clause).

  The restored set is not flagged in the database — by design it is exactly
  reproducible from the pinned line snapshot (the features
  `TransmissionLines.parse_geojson_feature/2` restores, keyed by stable
  `source_ID`). This module reproduces it the same way, twice per feature:

    1. against the PURE yard-voltage index built from the snapshot alone —
       this yields the circuit's ORIGINAL inferred voltage, and doubles as a
       provenance guard: a DB row whose voltage no longer equals the original
       inference was corrected by someone else (e.g. the corridor wave) and
       is left strictly alone;
    2. against the index AUGMENTED with the OSM-sourced yard levels
       (`substations.voltage_source = osm%`) at the yards' own coordinates —
       the same `:shared_level | :single_yard | :straddle | :default`
       rules now see real evidence where they previously saw nothing, so a
       circuit between two formerly-blind yards moves off the 138 kV default
       to what OSM says the yards actually run at.

  Changed rows get the new `voltage_kv`, `voltage_source: "osm_rederived"`
  (the value derives from OSM evidence and must stay extractable under
  ODbL), and `params_version: 0` in one update, exactly as ROADMAP item 24
  requires — the estimator otherwise leaves impedance and ratings on the old
  class (z_base scales with kV², so a 138->69 correction moves per-unit
  impedance 4x).
  """

  import Ecto.Query

  alias PowerModel.Repo
  alias PowerModel.Grid.{Substation, TransmissionLine}
  alias PowerModel.Ingestion.HIFLD.GeoJSON
  alias PowerModel.Ingestion.HIFLD.Names
  alias PowerModel.Ingestion.HIFLD.TransmissionLines

  @default_lines_snapshot "data/vendored/hifld_next_transmission_lines_v1.geojsonl"
  @kv_epsilon 0.01

  @doc """
  Compute (and with `apply: true`, write) the re-derivation.

  Returns a map with the proposal list, the `{old_kv, new_kv}` histogram,
  and the guard counts. Each proposal:
  `%{source_id, old_kv, new_kv, old_rule, new_rule}`.
  """
  def rederive(opts \\ []) do
    path = Keyword.get(opts, :lines_snapshot, @default_lines_snapshot)
    apply? = Keyword.get(opts, :apply, false)

    pure_index = TransmissionLines.build_yard_voltage_index(path)

    # `:extra_yard_entries` lets a DRY RUN see the yard levels the matcher
    # WOULD write (the DB rows only exist after apply); in apply mode the two
    # sources agree and the merge is a harmless union.
    additions =
      merge_index(osm_yard_entries(), Keyword.get(opts, :extra_yard_entries, %{}))

    augmented_index = merge_index(pure_index, additions)

    proposals =
      path
      |> GeoJSON.stream_features!()
      |> Stream.flat_map(fn feature ->
        with %{voltage_source: new_rule} = new_attrs when new_rule != :hifld <-
               TransmissionLines.parse_geojson_feature(feature, augmented_index),
             %{voltage_kv: old_kv, voltage_source: old_rule} <-
               TransmissionLines.parse_geojson_feature(feature, pure_index),
             false <- abs(new_attrs.voltage_kv - old_kv) < @kv_epsilon do
          [
            %{
              source_id: new_attrs.source_id,
              old_kv: old_kv,
              new_kv: new_attrs.voltage_kv,
              old_rule: old_rule,
              new_rule: new_rule
            }
          ]
        else
          _ -> []
        end
      end)
      |> Enum.to_list()

    {changeable, guarded, missing} = classify_against_db(proposals)

    # Full pre-change electrical params per row, captured into the audit so a
    # control run can undo this pass IN MEMORY on a later snapshot (the A/B
    # measurement convention) and the write stays reversible after the
    # estimator has repriced the rows.
    changeable = if apply?, do: attach_old_params(changeable), else: changeable

    applied = if apply?, do: apply_changes(changeable), else: 0

    %{
      osm_yards_in_index: map_size(additions),
      proposals: length(proposals),
      changeable: changeable,
      guarded_externally_corrected: guarded,
      missing_rows: missing,
      applied: applied,
      histogram:
        Enum.frequencies_by(changeable, fn p ->
          {Float.round(p.old_kv, 1), Float.round(p.new_kv, 1)}
        end),
      rule_shift: Enum.frequencies_by(changeable, fn p -> {p.old_rule, p.new_rule} end)
    }
  end

  # A DB row is only changeable when its current voltage still equals the
  # original inference — anything else was corrected by another pass and this
  # module must not overwrite it.
  defp classify_against_db(proposals) do
    db_voltages =
      proposals
      |> Enum.map(& &1.source_id)
      |> Enum.chunk_every(5000)
      |> Enum.flat_map(fn ids ->
        from(l in TransmissionLine,
          where: l.source == "hifld" and l.source_id in ^ids,
          select: {l.source_id, l.voltage_kv}
        )
        |> Repo.all()
      end)
      |> Map.new()

    Enum.reduce(proposals, {[], 0, 0}, fn p, {change, guarded, missing} ->
      case Map.fetch(db_voltages, p.source_id) do
        {:ok, kv} when abs(kv - p.old_kv) < @kv_epsilon -> {[p | change], guarded, missing}
        {:ok, _corrected} -> {change, guarded + 1, missing}
        :error -> {change, guarded, missing + 1}
      end
    end)
    |> then(fn {change, guarded, missing} -> {Enum.reverse(change), guarded, missing} end)
  end

  defp attach_old_params(changeable) do
    old_params =
      changeable
      |> Enum.map(& &1.source_id)
      |> Enum.chunk_every(5000)
      |> Enum.flat_map(fn ids ->
        from(l in TransmissionLine,
          where: l.source == "hifld" and l.source_id in ^ids,
          select:
            {l.source_id,
             %{
               line_id: l.id,
               voltage_kv: l.voltage_kv,
               r_pu: l.r_pu,
               x_pu: l.x_pu,
               b_pu: l.b_pu,
               rating_a_mva: l.rating_a_mva,
               rating_b_mva: l.rating_b_mva,
               rating_c_mva: l.rating_c_mva,
               params_version: l.params_version
             }}
        )
        |> Repo.all()
      end)
      |> Map.new()

    Enum.map(changeable, fn p -> Map.put(p, :old_params, Map.get(old_params, p.source_id)) end)
  end

  # Grouped by {old, new} so the write is a handful of update_alls; the WHERE
  # repeats the old-voltage guard so a concurrent correction between the read
  # and the write still cannot be overwritten.
  defp apply_changes(changeable) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    changeable
    |> Enum.group_by(&{&1.old_kv, &1.new_kv}, & &1.source_id)
    |> Enum.reduce(0, fn {{old_kv, new_kv}, source_ids}, applied ->
      source_ids
      |> Enum.chunk_every(5000)
      |> Enum.reduce(applied, fn ids, acc ->
        {count, _} =
          from(l in TransmissionLine,
            where:
              l.source == "hifld" and l.source_id in ^ids and
                fragment("abs(? - ?) < ?", l.voltage_kv, ^old_kv, ^@kv_epsilon)
          )
          |> Repo.update_all(
            set: [
              voltage_kv: new_kv,
              voltage_source: "osm_rederived",
              params_version: 0,
              updated_at: now
            ]
          )

        acc + count
      end)
    end)
  end

  # OSM-sourced yard levels as index entries at the yard's own coordinates,
  # under the same normalized-name key the restoration rules resolve with.
  # Empty before the migration that adds the column (pre-migration dry runs
  # see the would-be levels via `:extra_yard_entries` instead).
  defp osm_yard_entries do
    if not PowerModel.Ingestion.OSM.Matcher.voltage_source_column?() do
      %{}
    else
      osm_yard_entries_from_db()
    end
  end

  defp osm_yard_entries_from_db do
    from(s in Substation,
      where: like(s.voltage_source, "osm%") and not is_nil(s.coordinates),
      select: {s.name, s.coordinates, s.voltage_levels}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {name, coords, levels}, acc ->
      with true <- Names.identifying?(name),
           normalized when not is_nil(normalized) <- Names.normalize(name),
           %Geo.Point{coordinates: {lon, lat}} <- coords,
           [_ | _] <- levels do
        entries = Enum.map(levels, &{lon, lat, &1})
        Map.update(acc, normalized, entries, &(entries ++ &1))
      else
        _ -> acc
      end
    end)
  end

  defp merge_index(pure, additions) do
    Map.merge(pure, additions, fn _name, from_lines, from_osm -> from_osm ++ from_lines end)
  end
end
