defmodule PowerModel.Ingestion.EIA.Form860 do
  @moduledoc """
  Ingest generator data from EIA-860 Schedule 2/3 CSV files.
  """

  NimbleCSV.define(EIA860Parser, separator: ",", escape: "\"")

  require Logger

  alias PowerModel.Repo
  alias PowerModel.Grid.Generator

  def ingest(path) do
    generators_path = find_file(path, ~w(
      3_1_Generator_Y2024.csv
      3_1_Generator_Y2023.csv
      3_1_Generator_Y2022.csv
      generators.csv
    ))

    plant_path = find_file(path, ~w(
      2___Plant_Y2024.csv
      2___Plant_Y2023.csv
      2___Plant_Y2022.csv
      Plant_Y*.csv
    ))

    # Build plant coordinate lookup from Plant file
    plant_coords =
      if plant_path do
        build_plant_coords(plant_path)
      else
        %{}
      end

    if generators_path do
      generators_path
      |> File.stream!([:trim_bom])
      |> EIA860Parser.parse_stream(skip_headers: false)
      |> Stream.transform(nil, fn
        # First row is headers
        row, nil -> {[], row}
        row, headers -> {[Enum.zip(headers, row) |> Map.new()], headers}
      end)
      |> Flow.from_enumerable(max_demand: 200)
      |> Flow.map(&parse_generator(&1, plant_coords))
      |> Flow.filter(&(&1 != nil))
      |> Flow.map(&insert_generator/1)
      |> Flow.run()
    else
      {:error, "No EIA-860 generator file found at #{path}"}
    end
  end

  defp build_plant_coords(plant_path) do
    plant_path
    |> File.stream!([:trim_bom])
    |> EIA860Parser.parse_stream(skip_headers: false)
    |> Stream.transform(nil, fn
      row, nil -> {[], row}
      row, headers -> {[Enum.zip(headers, row) |> Map.new()], headers}
    end)
    |> Enum.reduce(%{}, fn row, acc ->
      plant_code = Map.get(row, "Plant Code")
      lat = parse_float(Map.get(row, "Latitude"))
      lon = parse_float(Map.get(row, "Longitude"))

      if plant_code && lat && lon do
        Map.put(acc, to_string(plant_code), {lon, lat})
      else
        acc
      end
    end)
  end

  defp parse_generator(row, plant_coords) do
    try do
      plant_id = Map.get(row, "Plant Code") || Map.get(row, "Plant ID")

      nameplate =
        parse_float(
          Map.get(row, "Nameplate Capacity (MW)") ||
            Map.get(row, "Capacity (MW)")
        )

      if plant_id && nameplate && nameplate > 0 do
        # Try coordinates from row first, then from plant lookup
        lat = parse_float(Map.get(row, "Latitude"))
        lon = parse_float(Map.get(row, "Longitude"))

        {lon, lat} =
          case {lon, lat} do
            {nil, _} -> Map.get(plant_coords, to_string(plant_id), {nil, nil})
            {_, nil} -> Map.get(plant_coords, to_string(plant_id), {nil, nil})
            pair -> pair
          end

        coords =
          if lat && lon do
            %Geo.Point{coordinates: {lon, lat}, srid: 4326}
          end

        %{
          eia_plant_id: to_string(plant_id),
          fuel_type: Map.get(row, "Energy Source 1") || Map.get(row, "Fuel Type"),
          prime_mover: Map.get(row, "Prime Mover") || Map.get(row, "Technology"),
          p_max_mw: nameplate,
          p_min_mw: parse_float(Map.get(row, "Minimum Load (MW)")) || 0.0,
          coordinates: coords,
          status: parse_status(Map.get(row, "Status") || Map.get(row, "Operating Status")),
          # Set by BusMapper
          bus_id: nil
        }
      end
    rescue
      _ -> nil
    end
  end

  defp insert_generator(nil), do: :ok

  defp insert_generator(attrs) do
    %Generator{}
    |> Generator.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing)
  end

  defp find_file(path, patterns) do
    Enum.find_value(patterns, fn pattern ->
      full = Path.join(path, pattern)

      case Path.wildcard(full) do
        [found | _] -> found
        [] -> nil
      end
    end)
  end

  defp parse_float(nil), do: nil
  defp parse_float(val) when is_number(val), do: val * 1.0

  defp parse_float(val) when is_binary(val) do
    cleaned = String.trim(val)

    case Float.parse(cleaned) do
      {f, _} -> f
      :error -> nil
    end
  end

  @doc """
  Maps an EIA-860 Schedule 3 generator status code to an internal status string.

  Only generators whose status is `"in_service"` are counted by the network
  builder and the load estimator (85% of in-service nameplate seeds the synthetic
  load baseline — see `PowerModel.Ingestion.LoadEstimator`). Any code that is not
  currently generating must therefore map to a non-`"in_service"` status, or it
  inflates that baseline.

  EIA-860 status codes:
    * `OP` operating                          -> `"in_service"`
    * `SB` standby / backup (available)       -> `"standby"`  (not counted, kept distinct)
    * `OS` out of service (exists, offline)   -> `"out_of_service"`
    * `RE` retired (permanently removed)      -> `"retired"`
    * `TS`/`T`/`U`/`V`/`L`/`P`/`OT` planned,  -> `"out_of_service"`
      proposed, under construction, other
    * `CN` cancelled                          -> `"out_of_service"`

  A missing status (absent column or blank cell) defaults to `"in_service"`, since
  the Schedule 3.1 file lists existing units. Any other, non-blank code is treated
  as `"out_of_service"` and logged, rather than silently counted as operating.
  """
  def parse_status(nil), do: "in_service"

  def parse_status(status) when is_binary(status) do
    case status |> String.trim() |> String.upcase() do
      "" ->
        "in_service"

      code when code in ~w(OP OPERATING) ->
        "in_service"

      code when code in ~w(SB STANDBY) ->
        "standby"

      "OS" ->
        "out_of_service"

      code when code in ~w(RE RETIRED) ->
        "retired"

      code when code in ~w(TS T U V L P OT CN) ->
        "out_of_service"

      code ->
        Logger.warning(
          "EIA-860: unrecognized generator status #{inspect(code)}; treating as out_of_service"
        )

        "out_of_service"
    end
  end
end
