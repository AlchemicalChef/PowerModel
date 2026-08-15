defmodule PowerModel.Ingestion.HIFLD.GeoJSON do
  @moduledoc """
  Streaming reader for the vendored HIFLD snapshots (see
  `data/vendored/PROVENANCE.md`).

  Two on-disk shapes are accepted, because the two snapshots arrive in
  different ones:

    * **GeoJSON Lines** (`.geojsonl` / `.ndjson`) — one complete Feature per
      line, no enclosing collection. `scripts/convert_vendored_hifld.py`
      writes the 94,619 transmission lines this way; as a single document
      they are ~500 MB, which has to be materialized whole to be decoded.
      Read line by line, they stream in constant memory.
    * **A single FeatureCollection** (`.geojson` / `.json`) — the substation
      mirror arrives this way (58 MB, 77,946 point features) and is decoded
      in one pass.

  The format is detected from the head of the file rather than the extension,
  so a `.geojson` holding newline-delimited features (or the reverse) still
  reads correctly.
  """

  # Enough to see the opening `{"type": "FeatureCollection"` of a collection
  # without reading a whole newline-delimited feature.
  @probe_bytes 512

  @doc """
  Stream the features of `path` as decoded maps (`"type"`, `"geometry"`,
  `"properties"`).

  Raises if the file is missing or does not decode.
  """
  def stream_features!(path) do
    if feature_collection?(path) do
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.get("features", [])
    else
      path
      |> File.stream!(:line)
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(&Jason.decode!/1)
    end
  end

  @doc """
  True when `path` holds one FeatureCollection document rather than
  newline-delimited features. Reads only the first #{@probe_bytes} bytes.
  """
  def feature_collection?(path) do
    head = File.open!(path, [:read, :binary], &IO.binread(&1, @probe_bytes))

    case head do
      :eof -> false
      binary when is_binary(binary) -> binary =~ ~r/"type"\s*:\s*"FeatureCollection"/
    end
  end

  @doc """
  Extract a Point feature's `{lon, lat}`, or nil for missing/other geometry.
  """
  def point_coordinates(%{"geometry" => %{"type" => "Point", "coordinates" => [lon, lat | _]}})
      when is_number(lon) and is_number(lat),
      do: {lon, lat}

  def point_coordinates(_), do: nil

  @doc """
  Extract a line feature's geometry as a list of PARTS, each a list of
  `{lon, lat}` tuples — the same shape
  `PowerModel.Ingestion.HIFLD.TransmissionLines.parse_paths/1` produces from
  ArcGIS `paths`, so a multi-part line never contributes a phantom bridge
  segment between its parts.

  A `LineString` is one part; a `MultiLineString` keeps its parts separate.
  Z (and any further) ordinates are dropped.
  """
  def line_parts(%{"geometry" => %{"type" => "LineString", "coordinates" => coords}}),
    do: normalize_parts([coords])

  def line_parts(%{"geometry" => %{"type" => "MultiLineString", "coordinates" => parts}})
      when is_list(parts),
      do: normalize_parts(parts)

  def line_parts(_), do: []

  defp normalize_parts(parts) do
    parts
    |> Enum.map(fn
      part when is_list(part) ->
        part
        |> Enum.map(fn
          [lon, lat | _] when is_number(lon) and is_number(lat) -> {lon * 1.0, lat * 1.0}
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end)
    |> Enum.filter(&(length(&1) >= 2))
  end
end
