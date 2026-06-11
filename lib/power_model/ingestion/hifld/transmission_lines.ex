defmodule PowerModel.Ingestion.HIFLD.TransmissionLines do
  @moduledoc """
  Ingest transmission lines from HIFLD Electric Power Transmission Lines.
  Supports both ArcGIS REST API and local shapefile sources.
  """

  alias PowerModel.Repo
  alias PowerModel.Grid.TransmissionLine
  alias PowerModel.Ingestion.HIFLD.API

  @service "Electric_Power_Transmission_Lines"

  @doc """
  Ingest from HIFLD ArcGIS REST API (default).
  """
  def ingest_from_api do
    {:ok, total} = API.count(@service)
    IO.puts("Fetching #{total} transmission lines from HIFLD API...")

    counter = :counters.new(1, [:atomics])

    @service
    |> API.stream_features()
    |> Stream.map(&parse_api_feature/1)
    |> Stream.filter(& &1)
    |> Stream.chunk_every(500)
    |> Stream.each(fn batch ->
      insert_batch(batch)
      :counters.add(counter, 1, length(batch))
      count = :counters.get(counter, 1)
      if rem(count, 2000) == 0, do: IO.puts("  #{count}/#{total} lines inserted...")
    end)
    |> Stream.run()

    final = :counters.get(counter, 1)
    IO.puts("Inserted #{final} transmission lines.")
    {:ok, final}
  end

  @doc """
  Ingest from local shapefile directory.
  """
  def ingest(path) do
    path
    |> read_shapefile()
    |> Flow.from_enumerable(max_demand: 100)
    |> Flow.map(&parse_shapefile_feature/1)
    |> Flow.filter(& &1)
    |> Flow.map(&insert_line/1)
    |> Flow.run()
  end

  @doc """
  Backfill HIFLD fields (TYPE, OWNER, SUB_1, SUB_2, NAICS) on existing records
  by re-fetching from the API and updating in place.
  """
  def backfill_hifld_fields do
    import Ecto.Query

    total =
      Repo.one(
        from tl in TransmissionLine,
          where: tl.source == "hifld" and is_nil(tl.sub_1),
          select: count()
      )

    IO.puts("Lines needing backfill: #{total}")

    if total == 0 do
      IO.puts("Nothing to backfill.")
      return_ok()
    end

    counter = :counters.new(1, [:atomics])

    @service
    |> API.stream_features()
    |> Stream.chunk_every(500)
    |> Stream.each(fn batch ->
      updates =
        Enum.map(batch, fn %{"attributes" => attrs} ->
          source_id = to_string(attrs["ID"] || attrs["OBJECTID_1"])

          {source_id,
           %{
             line_type: attrs["TYPE"],
             owner: attrs["OWNER"],
             sub_1: attrs["SUB_1"],
             sub_2: attrs["SUB_2"],
             naics_code: attrs["NAICS_CODE"],
             naics_desc: attrs["NAICS_DESC"]
           }}
        end)

      source_ids = Enum.map(updates, &elem(&1, 0))
      update_map = Map.new(updates)

      lines =
        Repo.all(
          from tl in TransmissionLine,
            where: tl.source == "hifld" and tl.source_id in ^source_ids
        )

      Enum.each(lines, fn line ->
        if fields = Map.get(update_map, line.source_id) do
          line
          |> Ecto.Changeset.change(fields)
          |> Repo.update()
        end
      end)

      :counters.add(counter, 1, length(batch))
      count = :counters.get(counter, 1)
      if rem(count, 5000) == 0, do: IO.puts("  Backfilled #{count} lines...")
    end)
    |> Stream.run()

    IO.puts("Backfill complete: #{:counters.get(counter, 1)} lines processed.")
    {:ok, :counters.get(counter, 1)}
  end

  defp return_ok, do: {:ok, 0}

  defp parse_api_feature(%{"attributes" => attrs, "geometry" => geom}) do
    try do
      voltage = parse_voltage(attrs["VOLTAGE"], attrs["VOLT_CLASS"])
      source_id = to_string(attrs["ID"] || attrs["OBJECTID_1"])

      paths = geom["paths"] || []

      coords =
        paths
        |> List.flatten()
        |> Enum.chunk_every(2)
        |> Enum.map(fn
          [lon, lat] -> {lon, lat}
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      coords =
        if coords == [] do
          paths
          |> Enum.flat_map(fn path ->
            Enum.map(path, fn
              [lon, lat | _] -> {lon, lat}
              _ -> nil
            end)
          end)
          |> Enum.reject(&is_nil/1)
        else
          coords
        end

      if voltage && voltage > 0 && length(coords) >= 2 do
        geometry = %Geo.LineString{coordinates: coords, srid: 4326}

        %{
          voltage_kv: voltage,
          geometry: geometry,
          source: "hifld",
          source_id: source_id,
          status: parse_status(attrs["STATUS"]),
          line_type: attrs["TYPE"],
          owner: attrs["OWNER"],
          sub_1: attrs["SUB_1"],
          sub_2: attrs["SUB_2"],
          naics_code: attrs["NAICS_CODE"],
          naics_desc: attrs["NAICS_DESC"],
          from_bus_id: nil,
          to_bus_id: nil
        }
      end
    rescue
      _e -> nil
    end
  end

  defp parse_api_feature(_), do: nil

  defp insert_batch(batch) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      Enum.map(batch, fn attrs ->
        %{
          voltage_kv: attrs.voltage_kv,
          geometry: attrs.geometry,
          source: attrs.source,
          source_id: attrs.source_id,
          status: attrs.status,
          line_type: attrs[:line_type],
          owner: attrs[:owner],
          sub_1: attrs[:sub_1],
          sub_2: attrs[:sub_2],
          naics_code: attrs[:naics_code],
          naics_desc: attrs[:naics_desc],
          from_bus_id: nil,
          to_bus_id: nil,
          r_pu: nil,
          x_pu: nil,
          b_pu: nil,
          rating_a_mva: nil,
          length_km: nil,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(TransmissionLine, entries,
      on_conflict: :nothing,
      conflict_target: [:source, :source_id]
    )
  end

  defp insert_line(nil), do: :ok

  defp insert_line(attrs) do
    %TransmissionLine{}
    |> TransmissionLine.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:source, :source_id])
  end

  defp read_shapefile(path) do
    shp_path = Path.join(path, "Electric_Power_Transmission_Lines.shp")

    if File.exists?(shp_path) do
      Exshape.from_zip(shp_path)
    else
      zip_path = Path.join(path, "Electric_Power_Transmission_Lines.zip")

      if File.exists?(zip_path) do
        Exshape.from_zip(zip_path)
      else
        raise "Transmission line shapefile not found at #{path}"
      end
    end
  end

  defp parse_shapefile_feature({shape, dbf_row}) do
    try do
      geometry = extract_linestring(shape)
      voltage = parse_voltage(get_field(dbf_row, "VOLTAGE"), get_field(dbf_row, "VOLT_CLASS"))
      source_id = to_string(get_field(dbf_row, "ID") || get_field(dbf_row, "OBJECTID"))

      if geometry && voltage && voltage > 0 do
        %{
          voltage_kv: voltage,
          geometry: geometry,
          source: "hifld",
          source_id: source_id,
          status: parse_status(get_field(dbf_row, "STATUS")),
          line_type: get_field(dbf_row, "TYPE"),
          owner: get_field(dbf_row, "OWNER"),
          sub_1: get_field(dbf_row, "SUB_1"),
          sub_2: get_field(dbf_row, "SUB_2"),
          naics_code: get_field(dbf_row, "NAICS_CODE"),
          naics_desc: get_field(dbf_row, "NAICS_DESC"),
          from_bus_id: nil,
          to_bus_id: nil
        }
      end
    rescue
      _e -> nil
    end
  end

  defp extract_linestring(%Exshape.Shp.Polyline{points: points}) when is_list(points) do
    coords =
      points
      |> List.flatten()
      |> Enum.map(fn
        %Exshape.Shp.Point{x: lon, y: lat} -> {lon, lat}
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    if length(coords) >= 2 do
      %Geo.LineString{coordinates: coords, srid: 4326}
    end
  end

  defp extract_linestring(_), do: nil

  defp get_field(row, field_name) when is_map(row) do
    Map.get(row, field_name) || Map.get(row, String.downcase(field_name))
  end

  defp get_field(_, _), do: nil

  defp parse_voltage(nil, volt_class), do: parse_volt_class(volt_class)
  defp parse_voltage(val, _) when is_number(val) and val > 0, do: val * 1.0

  defp parse_voltage(val, volt_class) when is_binary(val) do
    case Float.parse(String.trim(val)) do
      {f, _} when f > 0 -> f
      _ -> parse_volt_class(volt_class)
    end
  end

  defp parse_voltage(_, volt_class), do: parse_volt_class(volt_class)

  defp parse_volt_class(nil), do: nil

  defp parse_volt_class(val) when is_binary(val) do
    case Regex.run(~r/(\d+)\s*[-–]\s*(\d+)/, val) do
      [_, low, high] ->
        {l, _} = Integer.parse(low)
        {h, _} = Integer.parse(high)
        (l + h) / 2.0

      _ ->
        case Float.parse(String.replace(val, ~r/[^0-9.]/, "")) do
          {f, _} when f > 0 -> f
          _ -> nil
        end
    end
  end

  defp parse_volt_class(_), do: nil

  defp parse_status(nil), do: "in_service"

  defp parse_status(status) when is_binary(status) do
    if String.upcase(String.trim(status)) in ["IN SERVICE", "ACTIVE", "OPERATIONAL"],
      do: "in_service",
      else: "out_of_service"
  end

  defp parse_status(_), do: "in_service"
end
