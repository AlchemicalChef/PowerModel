defmodule PowerModel.Ingestion.OSM.Matcher do
  @moduledoc """
  Match voltage-blind HIFLD yards to voltage-tagged OSM substations and fill
  their `voltage_levels` (ROADMAP item 24, substation-voltage wave).

  ## Which yards are eligible

  Only yards for which the repo's own evidence is EXHAUSTED. Two classes:

    * **blind** — `voltage_levels = []` today; nothing anywhere.
    * **echo** — non-empty levels, but the yard has no native HIFLD
      MAX_VOLT/MIN_VOLT in the vendored layer AND no line of snapshot-carried
      voltage names it. Everything it stores was lent back by
      `augment_voltage_levels_from_lines/0` from TOPO-1 restored circuits
      whose voltage was itself inferred (mostly the 138 kV default) — a
      circular echo, not evidence.

  Yards with native voltage, or with levels lent by lines that carry their own
  HIFLD voltage, are NEVER touched (reconciling OSM against real HIFLD values
  is a separate wave; PROVENANCE.md's 40–60% HIFLD failure-rate note cuts
  both ways). Yards already `voltage_source = osm%` are skipped, which makes
  the pass idempotent.

  ## Match rule (measured on the Ohio bbox, scope dossier 2026-08-18)

  Nearest OSM voltage-tagged substation within #{250} m (61.3% of blind yards
  match; the distance curve is flat past 100 m, so matches are unambiguous).
  Guards, in order:

    1. **Ambiguity** — a second candidate within the radius with a DIFFERENT
       level set is only overridden by a clear name win (best similarity
       >= 0.5 and >= every rival's + 0.15); otherwise the yard is held.
    2. **Name veto** — when both sides carry a real name and similarity is
       < 0.35, the pair is held (the "CLUTCH SWITCH" 3 m from "Ross
       Substation" case: adjacent distinct yards). `UNKNOWN*`/`TAP*` keys
       carry no name signal and are matched on distance alone.
    3. **Line-voltage consistency** — every level real HIFLD lines lend the
       yard must sit within 5% of an OSM level, else held. (Vacuous for the
       eligible classes by construction; kept so widening eligibility cannot
       silently skip it.)

  Held evidence is still recorded in `osm_substation_matches` with the
  reason, so review does not need a re-run.
  """

  import Ecto.Query

  alias PowerModel.Repo
  alias PowerModel.Grid.{Bus, Substation}
  alias PowerModel.Ingestion.HIFLD.EndpointMatcher
  alias PowerModel.Ingestion.HIFLD.GeoJSON
  alias PowerModel.Ingestion.HIFLD.Names
  alias PowerModel.Ingestion.HIFLD.Substations, as: HIFLDSubstations
  alias PowerModel.Ingestion.HIFLD.TransmissionLines
  alias PowerModel.Ingestion.OSM.Substations, as: OSMSubstations
  alias PowerModel.Ingestion.OSM.SubstationMatch

  @match_radius_m 250.0
  @level_tolerance 0.05
  @name_veto_below 0.35
  @name_win_at 0.5
  @name_win_margin 0.15

  # ~550 m cells (lat); longitude cells shrink with cos(lat) — ~176 m at
  # Alaska's 71.5°N — so the candidate scan uses a 5x5 neighbourhood, which
  # covers the match radius at every US latitude.
  @cell_deg 0.005

  @default_substations_snapshot "data/vendored/hifld_substations_mirror_2021vintage.geojson"
  @default_lines_snapshot "data/vendored/hifld_next_transmission_lines_v1.geojsonl"

  @doc """
  The eligible yards, classed `:blind` / `:echo` (see the moduledoc), plus the
  real-line evidence levels per yard id (for the consistency guard).

  Reads the two vendored HIFLD snapshots to establish which yards have native
  voltage and which are named by a line of snapshot-carried voltage.
  """
  def eligible_yards(opts \\ []) do
    subs_path = Keyword.get(opts, :substations_snapshot, @default_substations_snapshot)
    lines_path = Keyword.get(opts, :lines_snapshot, @default_lines_snapshot)

    native = native_voltage_ids(subs_path)
    index = TransmissionLines.build_yard_voltage_index(lines_path)

    base = from(s in Substation, where: not is_nil(s.coordinates))

    # A DRY RUN is legitimate before the migration that adds
    # `voltage_source` has run; treat the missing column as all-nil.
    query =
      if voltage_source_column?() do
        from(s in base,
          select: %{
            id: s.id,
            name: s.name,
            hifld_id: s.hifld_id,
            levels: s.voltage_levels,
            voltage_source: s.voltage_source,
            coordinates: s.coordinates
          }
        )
      else
        from(s in base,
          select: %{
            id: s.id,
            name: s.name,
            hifld_id: s.hifld_id,
            levels: s.voltage_levels,
            voltage_source: nil,
            coordinates: s.coordinates
          }
        )
      end

    yards =
      query
      |> Repo.all()
      |> Enum.map(fn s ->
        %Geo.Point{coordinates: {lon, lat}} = s.coordinates
        Map.merge(s, %{lon: lon, lat: lat})
      end)

    {eligible, evidence} =
      Enum.reduce(yards, {[], %{}}, fn yard, {acc, ev} ->
        cond do
          yard.voltage_source != nil ->
            {acc, ev}

          yard.levels in [nil, []] ->
            {[Map.put(yard, :class, :blind) | acc], ev}

          MapSet.member?(native, yard.hifld_id) ->
            {acc, ev}

          true ->
            case real_line_levels(index, yard.name, yard.lon, yard.lat) do
              nil -> {[Map.put(yard, :class, :echo) | acc], ev}
              levels -> {acc, Map.put(ev, yard.id, levels)}
            end
        end
      end)

    %{eligible: Enum.reverse(eligible), real_line_levels: evidence}
  end

  @doc """
  Decide every eligible yard against the OSM snapshot WITHOUT writing.

  Returns `%{decisions: [...], stats: %{...}}`; each decision is
  `{:applied | :held, yard, candidate, method, similarity, distance_m, reason}`
  or `{:unmatched, yard}`.
  """
  def match(opts \\ []) do
    snapshot_path = Keyword.fetch!(opts, :snapshot)
    osm_subs = OSMSubstations.load_snapshot!(snapshot_path)
    eligibility = Keyword.get_lazy(opts, :eligibility, fn -> eligible_yards(opts) end)
    match_with(eligibility, osm_subs)
  end

  @doc """
  `match/1` against a precomputed eligibility and loaded snapshot, so the
  coordinator reads the vendored files once across passes.
  """
  def match_with(eligibility, osm_subs) do
    cells = build_cells(osm_subs)

    decisions =
      Enum.map(eligibility.eligible, fn yard ->
        decide(yard, candidates_near(cells, yard.lat, yard.lon), eligibility.real_line_levels)
      end)

    %{decisions: decisions, stats: decision_stats(decisions)}
  end

  @doc """
  Write the `:applied` decisions: substation levels + `voltage_source`, the
  evidence rows (applied AND held), and the single-default-bus retarget.
  Returns `%{applied: n, held: n, buses_retargeted: n, audit: [...]}`.

  The bus retarget: a yard in the eligible classes typically owns exactly one
  bus, created at the level list the yard had at `map_buses` time (138 kV for
  blind yards). When none of the new levels sits within 5% of that bus, the
  bus is moved to the highest new level — `base_kv` AND its
  `"<sub>_<kv>kV"` source key, so a later `create_substation_buses/0` run
  stays idempotent instead of duplicating the yard. Multi-bus yards are left
  alone and counted (proper multi-level rebuild is `map_buses` work).
  """
  def apply_decisions(decisions, opts \\ []) do
    snapshot_date = Keyword.get(opts, :snapshot_date, Date.utc_today())
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {applied, held} =
      Enum.reduce(decisions, {[], []}, fn
        {:applied, _, _, _, _, _, _} = d, {a, h} -> {[d | a], h}
        {:held, _, _, _, _, _, _} = d, {a, h} -> {a, [d | h]}
        {:unmatched, _}, acc -> acc
      end)

    audit =
      applied
      |> Enum.chunk_every(500)
      |> Enum.flat_map(fn chunk ->
        {:ok, entries} = Repo.transaction(fn -> apply_chunk(chunk, now, snapshot_date) end)
        entries
      end)

    insert_match_rows(held, "held", now, snapshot_date)

    %{
      applied: length(applied),
      held: length(held),
      buses_retargeted: Enum.count(audit, &is_map(&1.bus)),
      multi_bus_yards: Enum.count(audit, &(&1.bus == :multi)),
      audit: Enum.map(audit, &%{&1 | bus: if(&1.bus == :multi, do: nil, else: &1.bus)})
    }
  end

  defp apply_chunk(chunk, now, snapshot_date) do
    entries =
      Enum.map(chunk, fn {:applied, yard, cand, _method, _sim, _dist, _reason} ->
        levels = cand.levels_kv

        from(s in Substation, where: s.id == ^yard.id)
        |> Repo.update_all(
          set: [
            voltage_levels: levels,
            max_voltage_kv: List.first(levels),
            min_voltage_kv: if(length(levels) > 1, do: List.last(levels)),
            voltage_source: "osm_matched",
            updated_at: now
          ]
        )

        bus = retarget_default_bus(yard, levels, now)

        %{
          substation_id: yard.id,
          hifld_id: yard.hifld_id,
          class: yard.class,
          old_levels: yard.levels || [],
          new_levels: levels,
          new_source: "osm_matched",
          bus: bus
        }
      end)

    insert_match_rows(chunk, "applied", now, snapshot_date)
    entries
  end

  defp insert_match_rows(decisions, status, now, snapshot_date) do
    rows =
      Enum.map(decisions, fn {_tag, yard, cand, method, sim, dist, reason} ->
        %{
          substation_id: yard.id,
          osm_type: cand.type,
          osm_id: cand.id,
          osm_name: cand.name,
          raw_voltage: cand.raw_voltage,
          levels_kv: cand.levels_kv,
          distance_m: dist,
          name_similarity: sim,
          match_method: method,
          status: status,
          reason: reason,
          snapshot_date: snapshot_date,
          inserted_at: now,
          updated_at: now
        }
      end)

    rows
    |> Enum.chunk_every(500)
    |> Enum.each(
      &Repo.insert_all(SubstationMatch, &1,
        on_conflict: :nothing,
        conflict_target: [:substation_id, :osm_type, :osm_id]
      )
    )
  end

  @doc false
  def retarget_default_bus(yard, new_levels, now) do
    buses =
      from(b in Bus,
        where:
          b.source == "substation" and
            fragment("split_part(?, '_', 1) = ?", b.source_id, ^to_string(yard.id))
      )
      |> Repo.all()

    case buses do
      [bus] ->
        if Enum.any?(new_levels, &same_level?(&1, bus.base_kv)) do
          nil
        else
          target = hd(new_levels)
          new_source_id = "#{yard.id}_#{format_kv(target)}kV"

          from(b in Bus, where: b.id == ^bus.id)
          |> Repo.update_all(set: [base_kv: target, source_id: new_source_id, updated_at: now])

          %{
            bus_id: bus.id,
            old_base_kv: bus.base_kv,
            new_base_kv: target,
            old_source_id: bus.source_id,
            new_source_id: new_source_id
          }
        end

      [] ->
        nil

      _many ->
        :multi
    end
  end

  # -- decision logic ---------------------------------------------------------

  defp decide(yard, candidates, evidence) do
    case candidates do
      [] ->
        {:unmatched, yard}

      [{best, dist} | rest] ->
        cond do
          rest == [] or same_level_sets?([best | Enum.map(rest, &elem(&1, 0))]) ->
            guard(yard, best, dist, "distance", evidence)

          name_wins?(yard, best, Enum.map(rest, &elem(&1, 0))) ->
            guard(yard, best, dist, "distance+name", evidence)

          true ->
            {:held, yard, best, "distance", yard_similarity(yard, best), dist,
             "ambiguous: #{length(rest) + 1} candidates within #{trunc(@match_radius_m)} m with differing levels"}
        end
    end
  end

  defp guard(yard, best, dist, method, evidence) do
    sim = yard_similarity(yard, best)

    cond do
      sim != nil and sim < @name_veto_below ->
        {:held, yard, best, method, sim, dist,
         "name_mismatch: similarity #{Float.round(sim, 2)} below #{@name_veto_below}"}

      not consistent_with_evidence?(Map.get(evidence, yard.id), best.levels_kv) ->
        {:held, yard, best, method, sim, dist,
         "line_voltage_conflict: incident HIFLD line level not within 5% of any OSM level"}

      true ->
        {:applied, yard, best, method, sim, dist, nil}
    end
  end

  # No signal (nil) when either side has no real name: UNKNOWN*/TAP*/bare
  # sentinels carry a per-yard key, not a name.
  defp yard_similarity(yard, cand) do
    if HIFLDSubstations.sentinel_name?(yard.name || "") do
      nil
    else
      OSMSubstations.name_similarity(yard.name, cand.name)
    end
  end

  defp name_wins?(yard, best, rivals) do
    best_sim = yard_similarity(yard, best)

    best_sim != nil and best_sim >= @name_win_at and
      Enum.all?(rivals, fn rival ->
        best_sim >= (yard_similarity(yard, rival) || 0.0) + @name_win_margin
      end)
  end

  defp same_level_sets?(candidates) do
    candidates
    |> Enum.map(&Enum.map(&1.levels_kv, fn kv -> Float.round(kv, 1) end))
    |> Enum.uniq()
    |> length() == 1
  end

  defp consistent_with_evidence?(nil, _osm_levels), do: true

  defp consistent_with_evidence?(line_levels, osm_levels) do
    Enum.all?(line_levels, fn lv -> Enum.any?(osm_levels, &same_level?(&1, lv)) end)
  end

  defp same_level?(a, b), do: abs(a - b) / max(a, b) <= @level_tolerance

  defp decision_stats(decisions) do
    %{
      eligible: length(decisions),
      applied: Enum.count(decisions, &match?({:applied, _, _, _, _, _, _}, &1)),
      held: Enum.count(decisions, &match?({:held, _, _, _, _, _, _}, &1)),
      unmatched: Enum.count(decisions, &match?({:unmatched, _}, &1)),
      applied_by_class:
        decisions
        |> Enum.filter(&match?({:applied, _, _, _, _, _, _}, &1))
        |> Enum.frequencies_by(fn {_, yard, _, _, _, _, _} -> yard.class end),
      held_reasons:
        decisions
        |> Enum.filter(&match?({:held, _, _, _, _, _, _}, &1))
        |> Enum.frequencies_by(fn {_, _, _, _, _, _, reason} ->
          reason |> String.split(":") |> hd()
        end),
      applied_level_histogram:
        decisions
        |> Enum.filter(&match?({:applied, _, _, _, _, _, _}, &1))
        |> Enum.frequencies_by(fn {_, _, cand, _, _, _, _} ->
          Enum.map(cand.levels_kv, &Float.round(&1, 1))
        end)
    }
  end

  # -- eligibility helpers ----------------------------------------------------

  @doc "Whether `substations.voltage_source` exists yet (pre-migration dry runs)."
  def voltage_source_column? do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM information_schema.columns " <>
          "WHERE table_name = 'substations' AND column_name = 'voltage_source'"
      )

    rows != []
  end

  # hifld_ids of vendored features that carry a native MAX_VOLT or MIN_VOLT.
  defp native_voltage_ids(subs_path) do
    subs_path
    |> GeoJSON.stream_features!()
    |> Enum.reduce(MapSet.new(), fn %{"properties" => props}, acc ->
      native_id =
        (props["ID"] || props["OBJECTID"] || props["GlobalID"] || "")
        |> to_string()
        |> String.trim()

      has_voltage =
        HIFLDSubstations.sanitize_voltage(props["MAX_VOLT"]) ||
          HIFLDSubstations.sanitize_voltage(props["MIN_VOLT"])

      if native_id != "" and has_voltage, do: MapSet.put(acc, native_id), else: acc
    end)
  end

  # Levels lent to this yard by lines that carry their OWN voltage in the
  # snapshot — same name key and radius rule as the TOPO-1 restoration.
  defp real_line_levels(index, name, lon, lat) do
    with true <- Names.identifying?(name),
         [_ | _] = entries <- Map.get(index, Names.normalize(name), []) do
      entries
      |> Enum.filter(fn {elon, elat, _kv} ->
        EndpointMatcher.haversine_km(lat, lon, elat, elon) <=
          EndpointMatcher.name_match_radius_km()
      end)
      |> Enum.map(fn {_lon, _lat, kv} -> kv end)
      |> case do
        [] -> nil
        voltages -> HIFLDSubstations.cluster_voltage_levels(voltages)
      end
    else
      _ -> nil
    end
  end

  # -- spatial hash -----------------------------------------------------------

  defp build_cells(osm_subs) do
    Enum.group_by(osm_subs, &cell(&1.lat, &1.lon))
  end

  defp cell(lat, lon), do: {floor(lat / @cell_deg), floor(lon / @cell_deg)}

  defp candidates_near(cells, lat, lon) do
    {ci, cj} = cell(lat, lon)

    for di <- -2..2,
        dj <- -2..2,
        cand <- Map.get(cells, {ci + di, cj + dj}, []),
        dist = EndpointMatcher.haversine_km(lat, lon, cand.lat, cand.lon) * 1000.0,
        dist <= @match_radius_m do
      {cand, dist}
    end
    |> Enum.sort_by(&elem(&1, 1))
  end

  defp format_kv(kv), do: :erlang.float_to_binary(kv * 1.0, decimals: 1)
end
