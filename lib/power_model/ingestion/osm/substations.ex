defmodule PowerModel.Ingestion.OSM.Substations do
  @moduledoc """
  Parse the vendored OSM substation snapshot (ROADMAP item 24).

  The snapshot (`data/vendored/osm_substations_<date>.json`, fetched by
  `scripts/fetch_osm_voltage.py`, ODbL — see PROVENANCE.md) holds every US
  `power=substation` object with a `voltage` tag, tags + center point only.

  ## The voltage tag, as actually found (measured 2026-08-18, scope dossier)

    * Values are VOLTS, not kV: `"138000"`, `"69000"`.
    * Multi-level yards are semicolon-joined: `"345000;138000"`. Duplicated
      values occur (`"138000;138000"`, 2,070 US uses) — dedupe.
    * Transformer-through lists mix transmission and distribution
      (`"138000;12470"`) — only levels >= #{20} kV class the yard.
    * `"750"` (12,846 US uses) is DC rail traction, not a grid level — the
      kV floor removes it.

  `parse_voltage_levels/1` handles all of the above and returns descending
  kV levels deduped with the same 5% clustering the HIFLD side uses
  (`PowerModel.Ingestion.HIFLD.Substations.cluster_voltage_levels/1`), so an
  OSM `"115000;120000"` and a HIFLD 115/120 yard collapse identically.
  """

  alias PowerModel.Ingestion.HIFLD.Substations, as: HIFLDSubstations

  # Lowest voltage that counts as a yard level. Distribution feeders (12.47,
  # 14.4 kV) and rail traction (0.75 kV) sit below; 23 kV subtransmission and
  # up sit above. Matches the scope dossier's ">= ~20 kV" yard-classing rule.
  @min_yard_kv 20.0

  # Tokens that carry no identity when comparing a HIFLD yard name to an OSM
  # substation name ("FIRSTENERGY W H SAMMIS" vs "Sammis Substation").
  @name_stopwords ~w(
    SUBSTATION SUB SUBST STATION SWITCHYARD SWITCHING SWITCH YARD
    ELECTRIC POWER ENERGY TRANSMISSION DISTRIBUTION CO COMPANY CORP INC LLC
  )

  @doc """
  Load the vendored snapshot into a list of
  `%{type, id, name, raw_voltage, lat, lon, levels_kv}`.

  Elements without a usable center or with no parseable yard-class level are
  dropped (they carry no evidence a matcher can use).
  """
  def load_snapshot!(path) do
    doc = path |> File.read!() |> Jason.decode!()

    (doc["elements"] || [])
    |> Enum.flat_map(fn el ->
      raw = el["tags"]["voltage"]
      levels = parse_voltage_levels(raw)

      case {center(el), levels} do
        {{lat, lon}, [_ | _]} ->
          [
            %{
              type: el["type"],
              id: el["id"],
              name: el["tags"]["name"],
              raw_voltage: raw,
              lat: lat,
              lon: lon,
              levels_kv: levels
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp center(%{"lat" => lat, "lon" => lon}) when is_number(lat) and is_number(lon),
    do: {lat, lon}

  defp center(%{"center" => %{"lat" => lat, "lon" => lon}})
       when is_number(lat) and is_number(lon),
       do: {lat, lon}

  defp center(_), do: nil

  @doc """
  Parse an OSM `voltage` tag into descending yard levels in kV.

  Semicolon-split, volts -> kV, drops unparseable parts and anything below
  #{@min_yard_kv} kV (distribution and traction), then applies the HIFLD 5%
  level clustering. Returns `[]` when nothing survives.

      iex> PowerModel.Ingestion.OSM.Substations.parse_voltage_levels("345000;138000")
      [345.0, 138.0]
      iex> PowerModel.Ingestion.OSM.Substations.parse_voltage_levels("138000;138000")
      [138.0]
      iex> PowerModel.Ingestion.OSM.Substations.parse_voltage_levels("138000;12470")
      [138.0]
      iex> PowerModel.Ingestion.OSM.Substations.parse_voltage_levels("750")
      []
  """
  def parse_voltage_levels(raw) when is_binary(raw) do
    raw
    |> String.split(";")
    |> Enum.flat_map(fn part ->
      case Float.parse(String.trim(part)) do
        {volts, _} when volts > 0 -> [volts / 1000.0]
        _ -> []
      end
    end)
    |> Enum.filter(&(&1 >= @min_yard_kv))
    |> HIFLDSubstations.cluster_voltage_levels()
  end

  def parse_voltage_levels(_), do: []

  @doc """
  Similarity of a HIFLD yard name and an OSM substation name in `0.0..1.0`,
  or nil when either side offers no usable tokens.

  Token-based: both names are upcased, split on non-alphanumerics, and
  stripped of operator/suffix stopwords (#{Enum.join(Enum.take(@name_stopwords, 5), ", ")}, ...).
  The score is the fuzzy token overlap (Jaro >= 0.85 counts as the same
  token) over the smaller token set, so "FIRSTENERGY W H SAMMIS" vs
  "Sammis Substation" scores 1.0 while "CLUTCH SWITCH" vs "Ross Substation"
  scores 0.0.
  """
  def name_similarity(hifld_name, osm_name) do
    a = name_tokens(hifld_name)
    b = name_tokens(osm_name)

    if a == [] or b == [] do
      nil
    else
      {small, large} = if length(a) <= length(b), do: {a, b}, else: {b, a}

      matched =
        Enum.count(small, fn t ->
          Enum.any?(large, &(String.jaro_distance(t, &1) >= 0.85))
        end)

      overlap = matched / length(small)
      joined = String.jaro_distance(Enum.join(a, " "), Enum.join(b, " "))
      max(overlap, joined)
    end
  end

  @doc "Name tokens used by `name_similarity/2` (exposed for tests)."
  def name_tokens(nil), do: []

  def name_tokens(name) when is_binary(name) do
    name
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]+/, " ")
    |> String.split()
    |> Enum.reject(&(&1 in @name_stopwords))
  end
end
