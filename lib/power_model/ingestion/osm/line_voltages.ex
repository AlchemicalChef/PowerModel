defmodule PowerModel.Ingestion.OSM.LineVoltages do
  @moduledoc """
  Fallback voltage inference for yards no OSM substation matched: the voltages
  of OSM `power=line` / `power=minor_line` ways passing within
  #{120} m of the yard point (87% of US OSM power lines carry `voltage`).

  This is the OSM analogue of the HIFLD-side
  `Substations.augment_voltage_levels_from_lines/0` — a line that physically
  enters the yard terminates at (or passes over) one of its levels — and it
  is deliberately weaker evidence than a substation match, so the applied
  rows are marked `voltage_source = "osm_line_inferred"` and only yards the
  primary matcher left `:unmatched` are considered.

  The way snapshot (`data/vendored/osm_line_voltages_<date>.json`) is fetched
  by `scripts/fetch_osm_voltage.py lines --yards <csv>` with per-yard
  around-queries, so it only ever contains ways near the queried yards; the
  yard list is embedded in the file's metadata for reproducibility. Rail
  traction is excluded twice: the < 20 kV level floor, and a frequency-tag
  guard (16.7 Hz / 25 Hz networks are railway electrification, and 25 kV
  60 Hz Amtrak feeders still carry a `frequency` giveaway when tagged).
  """

  import Ecto.Query

  alias PowerModel.Repo
  alias PowerModel.Grid.Substation
  alias PowerModel.Ingestion.HIFLD.Substations, as: HIFLDSubstations
  alias PowerModel.Ingestion.OSM.Matcher
  alias PowerModel.Ingestion.OSM.Substations, as: OSMSubstations
  alias PowerModel.Ingestion.OSM.SubstationMatch

  @radius_m 120.0
  @cell_deg 0.005

  # Frequencies that mark railway electrification, not the grid.
  @traction_frequencies ~w(16.7 16.67 16.66 25)

  @doc """
  Load the vendored way snapshot into
  `[%{id, raw_voltage, levels_kv, geometry: [{lat, lon}, ...]}]`,
  dropping untagged, unparseable, and traction ways.
  """
  def load_snapshot!(path) do
    doc = path |> File.read!() |> Jason.decode!()

    (doc["elements"] || [])
    |> Enum.flat_map(fn el ->
      tags = el["tags"] || %{}
      levels = OSMSubstations.parse_voltage_levels(tags["voltage"])
      geometry = for %{"lat" => lat, "lon" => lon} <- el["geometry"] || [], do: {lat, lon}

      if el["type"] == "way" and levels != [] and length(geometry) >= 2 and
           tags["frequency"] not in @traction_frequencies do
        [%{id: el["id"], raw_voltage: tags["voltage"], levels_kv: levels, geometry: geometry}]
      else
        []
      end
    end)
  end

  @doc """
  Infer levels for `yards` (maps with `:id`, `:lat`, `:lon`) from `ways`.

  Returns `[%{yard: yard, levels: [...], ways: [{way, distance_m}, ...]}]`
  for the yards at least one way passes within #{@radius_m} m of.
  """
  def infer(yards, ways) do
    cells = build_way_cells(ways)

    Enum.flat_map(yards, fn yard ->
      hits =
        cells
        |> ways_near(yard.lat, yard.lon)
        |> Enum.map(&{&1, distance_to_way_m(yard.lat, yard.lon, &1.geometry)})
        |> Enum.filter(fn {_way, d} -> d <= @radius_m end)
        |> Enum.sort_by(&elem(&1, 1))

      levels =
        hits
        |> Enum.flat_map(fn {way, _d} -> way.levels_kv end)
        |> HIFLDSubstations.cluster_voltage_levels()

      if levels == [] do
        []
      else
        [%{yard: yard, levels: levels, ways: hits}]
      end
    end)
  end

  @doc """
  Write the inferences: yard levels + `voltage_source = "osm_line_inferred"`,
  one evidence row per contributing way, and the default-bus retarget (same
  rule as the primary matcher). Returns `%{applied: n, buses_retargeted: n,
  audit: [...]}`.
  """
  def apply_inferences(inferences, opts \\ []) do
    snapshot_date = Keyword.get(opts, :snapshot_date, Date.utc_today())
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    audit =
      inferences
      |> Enum.chunk_every(500)
      |> Enum.flat_map(fn chunk ->
        {:ok, entries} =
          Repo.transaction(fn -> Enum.map(chunk, &apply_one(&1, now, snapshot_date)) end)

        entries
      end)

    %{
      applied: length(audit),
      buses_retargeted: Enum.count(audit, &is_map(&1.bus)),
      multi_bus_yards: Enum.count(audit, &(&1.bus == :multi)),
      audit: Enum.map(audit, &%{&1 | bus: if(&1.bus == :multi, do: nil, else: &1.bus)})
    }
  end

  defp apply_one(%{yard: yard, levels: levels, ways: ways}, now, snapshot_date) do
    from(s in Substation, where: s.id == ^yard.id)
    |> Repo.update_all(
      set: [
        voltage_levels: levels,
        max_voltage_kv: List.first(levels),
        min_voltage_kv: if(length(levels) > 1, do: List.last(levels)),
        voltage_source: "osm_line_inferred",
        updated_at: now
      ]
    )

    rows =
      Enum.map(ways, fn {way, dist} ->
        %{
          substation_id: yard.id,
          osm_type: "way",
          osm_id: way.id,
          osm_name: nil,
          raw_voltage: way.raw_voltage,
          levels_kv: way.levels_kv,
          distance_m: dist,
          name_similarity: nil,
          match_method: "line_inferred",
          status: "applied",
          reason: nil,
          snapshot_date: snapshot_date,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(SubstationMatch, rows,
      on_conflict: :nothing,
      conflict_target: [:substation_id, :osm_type, :osm_id]
    )

    bus = Matcher.retarget_default_bus(yard, levels, now)

    %{
      substation_id: yard.id,
      hifld_id: yard.hifld_id,
      class: yard.class,
      old_levels: yard.levels || [],
      new_levels: levels,
      new_source: "osm_line_inferred",
      bus: bus
    }
  end

  # -- geometry ---------------------------------------------------------------

  # Min distance from the point to any segment of the way, in metres, on a
  # local equirectangular plane (exact enough at the ~100 m scale this runs at).
  @doc false
  def distance_to_way_m(lat, lon, geometry) do
    kx = 111_320.0 * :math.cos(lat * :math.pi() / 180.0)
    ky = 110_540.0

    geometry
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [{lat1, lon1}, {lat2, lon2}] ->
      point_segment_distance(
        {(lon1 - lon) * kx, (lat1 - lat) * ky},
        {(lon2 - lon) * kx, (lat2 - lat) * ky}
      )
    end)
    |> Enum.min()
  end

  # Distance from the origin to segment AB.
  defp point_segment_distance({ax, ay}, {bx, by}) do
    dx = bx - ax
    dy = by - ay
    len_sq = dx * dx + dy * dy

    t =
      if len_sq == 0.0 do
        0.0
      else
        max(0.0, min(1.0, -(ax * dx + ay * dy) / len_sq))
      end

    px = ax + t * dx
    py = ay + t * dy
    :math.sqrt(px * px + py * py)
  end

  # -- spatial hash -----------------------------------------------------------

  # Ways indexed by every cell their SEGMENTS pass through (sampled at
  # sub-cell steps — tower nodes can be sparse on straight spans), padded one
  # cell so a lookup at the yard's own cell always sees every way within the
  # radius.
  defp build_way_cells(ways) do
    Enum.reduce(ways, %{}, fn way, acc ->
      way.geometry
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [a, b] -> sample_segment(a, b) end)
      |> Enum.flat_map(fn {lat, lon} ->
        {ci, cj} = cell(lat, lon)
        for di <- -1..1, dj <- -1..1, do: {ci + di, cj + dj}
      end)
      |> Enum.uniq()
      |> Enum.reduce(acc, fn key, inner ->
        Map.update(inner, key, [way], &[way | &1])
      end)
    end)
  end

  defp sample_segment({lat1, lon1} = a, {lat2, lon2} = b) do
    steps = ceil(max(abs(lat2 - lat1), abs(lon2 - lon1)) / (@cell_deg / 2.0))

    if steps <= 1 do
      [a, b]
    else
      for i <- 0..steps do
        t = i / steps
        {lat1 + t * (lat2 - lat1), lon1 + t * (lon2 - lon1)}
      end
    end
  end

  defp ways_near(cells, lat, lon) do
    cells |> Map.get(cell(lat, lon), []) |> Enum.uniq_by(& &1.id)
  end

  defp cell(lat, lon), do: {floor(lat / @cell_deg), floor(lon / @cell_deg)}
end
