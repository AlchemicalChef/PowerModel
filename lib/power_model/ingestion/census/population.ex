defmodule PowerModel.Ingestion.Census.Population do
  @moduledoc """
  Ingest county resident population with county centroids from two public
  Census Bureau bulk files (no API key):

    * `co-est<year>-alldata.csv` — Population Estimates Program county totals
      (https://www2.census.gov/programs-surveys/popest/datasets/, county
      totals). Latest `POPESTIMATE<year>` column is used.
    * `<year>_Gaz_counties_national.txt` — Gazetteer county interior points
      (https://www2.census.gov/geo/docs/maps-data/data/gazetteer/),
      tab-delimited GEOID/INTPTLAT/INTPTLONG.

  Joined on 5-digit county FIPS. Rows are upserted on `fips`, and rows whose
  FIPS is absent from the ingested file are DELETED afterwards (DAT-6):
  county definitions change between vintages (e.g. Connecticut's 2022 switch
  from 8 counties to 9 planning regions), and keeping stale FIPS alongside
  their replacements double-counts population in the load weights.

  ## What this table does NOT have

  A boundary. The Gazetteer publishes an interior POINT per county and nothing
  else, and no tract or block-group file is vendored, so
  `PowerModel.Ingestion.LoadEstimator` cannot spread a county's population over
  its polygon directly. It infers the county's extent from the spacing of
  neighbouring interior points instead — counties tile the country without
  gaps, so that spacing measures local county size. `counties/0` is the reader
  that feeds it; the calibration of the inference is documented at
  `LoadEstimator.spread_radii/1`.
  """

  NimbleCSV.define(CensusPopParser, separator: ",", escape: "\"")
  NimbleCSV.define(CensusGazParser, separator: "\t", escape: "\"")

  import Ecto.Query

  alias PowerModel.Repo
  alias PowerModel.Demographics.CountyPopulation

  @batch_size 500
  @county_sumlev "050"

  @doc """
  Ingest county population. `path` may be a directory containing both files
  (globbed as `co-est*-alldata.csv` / `*_Gaz_counties_national.txt`) or a
  keyword list `[popest: file, gazetteer: file]`.
  """
  def ingest(path) when is_binary(path) do
    popest = single_match(Path.join(path, "co-est*-alldata.csv"))
    gazetteer = single_match(Path.join(path, "*_Gaz_counties_national.txt"))
    ingest(popest: popest, gazetteer: gazetteer)
  end

  def ingest(popest: popest, gazetteer: gazetteer) do
    IO.puts(
      "Ingesting county population from #{Path.basename(popest)} + #{Path.basename(gazetteer)}..."
    )

    centroids = parse_gazetteer(gazetteer)
    counties = parse_popest(popest)

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {rows, missing} =
      Enum.reduce(counties, {[], []}, fn county, {rows, missing} ->
        case Map.fetch(centroids, county.fips) do
          {:ok, {lon, lat}} ->
            row = %{
              fips: county.fips,
              name: county.name,
              state: county.state,
              population: county.population,
              coordinates: %Geo.Point{coordinates: {lon, lat}, srid: 4326},
              inserted_at: now,
              updated_at: now
            }

            {[row | rows], missing}

          :error ->
            {rows, [county.fips | missing]}
        end
      end)

    rows
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn batch ->
      Repo.insert_all(CountyPopulation, batch,
        on_conflict: {:replace, [:name, :state, :population, :coordinates, :updated_at]},
        conflict_target: [:fips]
      )
    end)

    total_pop = rows |> Enum.map(& &1.population) |> Enum.sum()
    IO.puts("  #{length(rows)} counties upserted, total population #{total_pop}.")

    # DAT-6: drop counties from prior vintages that this file no longer
    # defines, so mixed vintages cannot double-count. (Skipped for an empty
    # ingest — that would wipe the table rather than refresh it.)
    ingested_fips = Enum.map(rows, & &1.fips)

    if ingested_fips != [] do
      {stale, _} =
        Repo.delete_all(from cp in CountyPopulation, where: cp.fips not in ^ingested_fips)

      if stale > 0 do
        IO.puts("  #{stale} stale counties deleted (FIPS not present in ingested file).")
      end
    end

    if missing != [] do
      IO.puts(
        "  #{length(missing)} counties without a Gazetteer centroid (skipped): #{Enum.join(Enum.take(missing, 10), ", ")}"
      )
    end

    {:ok, length(rows)}
  end

  @doc """
  `[%{id, fips, population, lon, lat}]` for every ingested county with a
  centroid — the input to the load allocator's spatial spread.
  """
  def counties do
    from(c in CountyPopulation,
      where: not is_nil(c.coordinates),
      select: %{id: c.id, fips: c.fips, population: c.population, coordinates: c.coordinates}
    )
    |> Repo.all()
    |> Enum.map(fn c ->
      %Geo.Point{coordinates: {lon, lat}} = c.coordinates
      c |> Map.delete(:coordinates) |> Map.merge(%{lon: lon, lat: lat})
    end)
  end

  defp single_match(glob) do
    case Path.wildcard(glob) do
      [file] -> file
      [] -> raise "no file matching #{glob}"
      files -> raise "multiple files match #{glob}: #{inspect(files)} — pass explicit paths"
    end
  end

  # popest CSVs ship as Latin-1 (county names like Doña Ana); convert so
  # Postgres doesn't reject the batch on invalid UTF-8.
  defp read_utf8!(file) do
    raw = File.read!(file)

    if String.valid?(raw) do
      raw
    else
      :unicode.characters_to_binary(raw, :latin1, :utf8)
    end
  end

  defp parse_popest(file) do
    [header | data] = read_utf8!(file) |> CensusPopParser.parse_string(skip_headers: false)

    idx = header |> Enum.with_index() |> Map.new()

    pop_col =
      header
      |> Enum.filter(&String.starts_with?(&1, "POPESTIMATE"))
      |> Enum.max(fn -> raise "no POPESTIMATE column in #{file}; headers: #{inspect(header)}" end)

    fetch = fn row, col -> Enum.at(row, Map.fetch!(idx, col)) end

    data
    |> Enum.filter(fn row -> fetch.(row, "SUMLEV") == @county_sumlev end)
    |> Enum.map(fn row ->
      state_fips = fetch.(row, "STATE") |> String.pad_leading(2, "0")
      county_fips = fetch.(row, "COUNTY") |> String.pad_leading(3, "0")

      %{
        fips: state_fips <> county_fips,
        name: fetch.(row, "CTYNAME"),
        state: fetch.(row, "STNAME"),
        population: fetch.(row, pop_col) |> String.trim() |> String.to_integer()
      }
    end)
  end

  defp parse_gazetteer(file) do
    [header | data] = read_utf8!(file) |> CensusGazParser.parse_string(skip_headers: false)

    # Gazetteer pads the last column with trailing whitespace
    header = Enum.map(header, &String.trim/1)
    idx = header |> Enum.with_index() |> Map.new()

    for row <- data, into: %{} do
      geoid = Enum.at(row, Map.fetch!(idx, "GEOID")) |> String.trim()
      lat = Enum.at(row, Map.fetch!(idx, "INTPTLAT")) |> String.trim() |> parse_float!()
      lon = Enum.at(row, Map.fetch!(idx, "INTPTLONG")) |> String.trim() |> parse_float!()
      {geoid, {lon, lat}}
    end
  end

  defp parse_float!(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> raise "unparseable coordinate: #{inspect(s)}"
    end
  end
end
