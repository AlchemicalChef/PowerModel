defmodule PowerModel.Ingestion.EIA.Form861 do
  @moduledoc """
  Behind-the-meter solar PV from EIA-861, landed on network buses
  (ROADMAP Phase 2.5 item 30).

  ## Source

  `data/f8612024.zip` (https://www.eia.gov/electricity/data/eia861/zip/f8612024.zip
  — no API key). Three sheets are read:

    * `Net_Metering_2024.xlsx` / **States** — net-metered PV capacity MW by
      utility x state x sector. 50.6 GW nationally.
    * `Non_Net_Metering_Distributed_2024.xlsx` / **States_ Utility Level** —
      distributed PV that is not net metered. 3.3 GW.
    * `Service_Territory_2024.xlsx` / **Counties_States** — which counties each
      utility serves. 11,776 utility-county pairs.

  Two sheets are deliberately NOT summed in:

    * **TPO** (third-party-owned, 10.3 GW) is a breakout of net-metered
      capacity — the host utility already reports those systems on the States
      sheet. Adding it would double count and push the national total to
      64 GW, past EIA's published ~50 GW small-scale estimate.
    * **Direct Connected** capacity in the non-net-metering file sits on the
      distribution system rather than behind a customer meter, so it is not
      behind-the-meter and is not netted out of EIA-930 demand.

  Territories (PR, VI, GU, AS) and EIA's state "Adjustment" rows (utility
  99999, which carry negative capacity to reconcile non-respondents) are
  skipped and reported.

  ## Multi-row stacked headers

  The 861 workbooks stack merged header rows, and the leaf labels repeat: the
  Net_Metering sheet has THREE header rows and its "Capacity MW / Residential"
  pair occurs four times — once each under Photovoltaic, Wind, Other, and All
  Technologies. A column is therefore addressed by its full header PATH
  (`["photovoltaic", "capacity mw", "residential"]`) against forward-filled
  header rows, and the parse fails loudly if a path does not resolve to
  exactly one column.

  ## Allocation chain

      utility x state x sector capacity   (EIA-861)
        -> counties of that utility in that state   (Service_Territory)
        -> population-weighted split across those counties
        -> buses, by the same county->bus KNN the load estimator uses

  Each utility is allocated independently and contributions SUM, so a county
  served by three utilities receives all three.

  Simplifications, deliberate this round:

    * Commercial and industrial capacity uses the same population weights as
      residential. Rooftop C&I actually tracks commercial floorspace, which the
      model does not carry; population is the available proxy.
    * A utility whose counties cannot be matched at all falls back to a
      population-weighted spread over its whole state. This is what covers
      Connecticut, where the Census replaced counties with nine planning
      regions in 2022 while EIA-861 still files the eight legacy county names —
      and CT's territory is covered end to end by two utilities, so the state
      spread loses little. Alaska's renamed census areas ride the same path.
  """

  import Ecto.Query
  require Logger

  alias PowerModel.Grid.BtmSolar
  alias PowerModel.Repo

  NimbleCSV.define(EIA861Parser, separator: ",", escape: "\"")

  @sector_columns [
    {"residential", "Residential"},
    {"commercial", "Commercial"},
    {"industrial", "Industrial"}
  ]

  # EIA's non-respondent reconciliation rows, which carry negative capacity and
  # no service territory.
  @adjustment_utility "99999"

  # Below 1 kW a bus row is rounding noise from the KNN spread, not capacity.
  # Without the floor the 3,144-county spread produces ~250k rows, most of them
  # microwatts.
  @min_capacity_mw 0.001

  # County-type suffixes, longest first: "Juneau City and Borough" must lose
  # the whole phrase, not just "borough", and must not then look like a
  # Virginia independent city.
  @county_suffixes [
    "city and borough",
    "census area",
    "planning region",
    "municipality",
    "municipio",
    "borough",
    "parish",
    "county",
    "district"
  ]

  @state_abbreviations %{
    "alabama" => "AL",
    "alaska" => "AK",
    "arizona" => "AZ",
    "arkansas" => "AR",
    "california" => "CA",
    "colorado" => "CO",
    "connecticut" => "CT",
    "delaware" => "DE",
    "district of columbia" => "DC",
    "florida" => "FL",
    "georgia" => "GA",
    "hawaii" => "HI",
    "idaho" => "ID",
    "illinois" => "IL",
    "indiana" => "IN",
    "iowa" => "IA",
    "kansas" => "KS",
    "kentucky" => "KY",
    "louisiana" => "LA",
    "maine" => "ME",
    "maryland" => "MD",
    "massachusetts" => "MA",
    "michigan" => "MI",
    "minnesota" => "MN",
    "mississippi" => "MS",
    "missouri" => "MO",
    "montana" => "MT",
    "nebraska" => "NE",
    "nevada" => "NV",
    "new hampshire" => "NH",
    "new jersey" => "NJ",
    "new mexico" => "NM",
    "new york" => "NY",
    "north carolina" => "NC",
    "north dakota" => "ND",
    "ohio" => "OH",
    "oklahoma" => "OK",
    "oregon" => "OR",
    "pennsylvania" => "PA",
    "rhode island" => "RI",
    "south carolina" => "SC",
    "south dakota" => "SD",
    "tennessee" => "TN",
    "texas" => "TX",
    "utah" => "UT",
    "vermont" => "VT",
    "virginia" => "VA",
    "washington" => "WA",
    "west virginia" => "WV",
    "wisconsin" => "WI",
    "wyoming" => "WY"
  }

  @state_codes @state_abbreviations |> Map.values() |> MapSet.new()

  @doc """
  Ingest BTM solar from the EIA-861 files in `data_dir`.

  Idempotent by **delete-and-rebuild**: the whole `btm_solar` table is replaced
  inside one transaction. Upsert would leave behind rows for buses that a
  re-mapped network no longer reaches, and the allocation is a single global
  spread anyway — there is no partial-update case to preserve.

  Returns `{:ok, report}` with the coverage counters, or `{:error, reason}`.
  """
  def run(data_dir \\ "data") do
    with {:ok, files} <- locate_files(data_dir),
         {:ok, capacity_rows} <- read_capacity(files),
         {:ok, named_territories} <- read_territories(files) do
      {counties, lookup} = county_index()

      if map_size(counties) == 0 do
        IO.puts("  No county population data. Run `mix power_model.ingest population` first.")
        {:error, :no_county_population}
      else
        {territories, unmatched} = resolve_territories(named_territories, lookup)

        if MapSet.size(unmatched) > 0 do
          IO.puts(
            "  #{MapSet.size(unmatched)} county names had no Census match " <>
              "(their utilities fall back to a state-level spread): " <>
              (unmatched |> Enum.sort() |> Enum.take(6) |> inspect())
          )
        end

        ingest(capacity_rows, territories, counties, bus_shares())
      end
    else
      {:error, reason} = error ->
        IO.puts("  EIA-861 BTM solar not ingested: #{inspect(reason)}")
        error
    end
  end

  defp ingest(capacity_rows, territories, counties, shares) do
    {rows, report} = allocate(capacity_rows, territories, counties, shares)

    case replace_all(rows) do
      {:ok, n} ->
        report = Map.put(report, :rows_inserted, n)
        print_report(report)
        {:ok, report}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Replace the whole `btm_solar` table with `rows`, in one transaction.

  This is what makes the stage idempotent: re-running rebuilds rather than
  merges, so a re-mapped network cannot leave capacity stranded on buses the
  new allocation never chose.
  """
  def replace_all(rows) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.transaction(
      fn ->
        Repo.delete_all(BtmSolar)

        rows
        |> Enum.map(&Map.merge(&1, %{inserted_at: now, updated_at: now}))
        |> Enum.chunk_every(1000)
        |> Enum.reduce(0, fn batch, count ->
          {n, _} = Repo.insert_all(BtmSolar, batch)
          count + n
        end)
      end,
      timeout: :infinity
    )
  end

  # ---------------------------------------------------------------- allocation

  @doc """
  Spread utility x state x sector capacity onto buses. Pure — every input is
  data, so the whole chain is testable without a database.

    * `capacity_rows` — `[%{utility_id, state, sector, capacity_mw}]`
    * `territories` — `%{{utility_id, state} => [fips]}`
    * `counties` — `%{fips => %{population: n, state: "CA"}}`
    * `shares` — `%{fips => [{bus_id, share}]}`, shares summing to 1 per county

  Returns `{rows, report}` where rows are the `btm_solar` records, one per
  `{bus_id, sector}`, and `report` carries the MW counters.
  """
  def allocate(capacity_rows, territories, counties, shares) do
    counties_by_state =
      counties
      |> Enum.group_by(fn {_fips, c} -> c.state end, fn {fips, _c} -> fips end)

    initial = %{
      total_mw: 0.0,
      allocated_mw: 0.0,
      state_fallback_mw: 0.0,
      no_territory_mw: 0.0,
      no_bus_mw: 0.0
    }

    {acc, report} =
      Enum.reduce(capacity_rows, {%{}, initial}, fn row, {acc, report} ->
        report = Map.update!(report, :total_mw, &(&1 + row.capacity_mw))

        {fips_list, report} =
          case Map.get(territories, {row.utility_id, row.state}, []) do
            [] ->
              fallback = Map.get(counties_by_state, row.state, [])

              report =
                if fallback == [],
                  do: Map.update!(report, :no_territory_mw, &(&1 + row.capacity_mw)),
                  else: Map.update!(report, :state_fallback_mw, &(&1 + row.capacity_mw))

              {fallback, report}

            list ->
              {list, report}
          end

        spread_row(row, fips_list, counties, shares, acc, report)
      end)

    rows = build_rows(acc)
    {rows, finish_report(report, rows)}
  end

  defp spread_row(_row, [], _counties, _shares, acc, report), do: {acc, report}

  defp spread_row(row, fips_list, counties, shares, acc, report) do
    weights = county_weights(fips_list, counties)

    Enum.reduce(weights, {acc, report}, fn {fips, weight}, {acc, report} ->
      county_mw = row.capacity_mw * weight

      case Map.get(shares, fips, []) do
        [] ->
          {acc, Map.update!(report, :no_bus_mw, &(&1 + county_mw))}

        bus_shares ->
          acc =
            Enum.reduce(bus_shares, acc, fn {bus_id, share}, acc ->
              add_contribution(acc, bus_id, row, county_mw * share)
            end)

          {acc, Map.update!(report, :allocated_mw, &(&1 + county_mw))}
      end
    end)
  end

  # Population share within the utility's counties. A utility whose counties
  # are all unpopulated still gets its capacity placed, split evenly.
  defp county_weights(fips_list, counties) do
    populations =
      Enum.map(fips_list, fn fips ->
        {fips, (counties[fips] && counties[fips].population) || 0}
      end)

    total = populations |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if total > 0 do
      Enum.map(populations, fn {fips, pop} -> {fips, pop / total} end)
    else
      share = 1.0 / length(fips_list)
      Enum.map(populations, fn {fips, _pop} -> {fips, share} end)
    end
  end

  # The unique index is on {bus_id, sector}, so contributions from every
  # utility reaching this bus fold into one row. Provenance keeps only the
  # largest contributor rather than a full per-utility map — that would be
  # ~250k nested maps to answer a question no consumer asks.
  defp add_contribution(acc, bus_id, row, mw) do
    Map.update(acc, {bus_id, row.sector}, {mw, mw, row.utility_id, row.state}, fn
      {total, best_mw, best_utility, best_state} ->
        if mw > best_mw do
          {total + mw, mw, row.utility_id, row.state}
        else
          {total + mw, best_mw, best_utility, best_state}
        end
    end)
  end

  defp build_rows(acc) do
    acc
    |> Enum.reduce([], fn {{bus_id, sector}, {mw, _best, utility, state}}, rows ->
      if mw >= @min_capacity_mw do
        [
          %{
            bus_id: bus_id,
            sector: sector,
            capacity_mw: Float.round(mw, 6),
            state: state,
            utility_id: utility
          }
          | rows
        ]
      else
        rows
      end
    end)
  end

  defp finish_report(report, rows) do
    written_mw = rows |> Enum.map(& &1.capacity_mw) |> Enum.sum()

    report
    |> Map.put(:written_mw, written_mw)
    |> Map.put(:below_floor_mw, report.allocated_mw - written_mw)
    |> Map.put(:unallocated_mw, report.total_mw - report.allocated_mw)
  end

  # ------------------------------------------------------------- database side

  @doc """
  Reads `county_population` into the two shapes the allocation needs:

    * `counties` — `%{fips => %{population: n, state: "CA"}}`
    * `lookup` — `%{{state, normalized_key} => fips}`, how an EIA-861 county
      string finds its FIPS code

  `county_population.state` holds full names ("Alabama") while 861 uses
  two-letter codes, so states resolve through `@state_abbreviations`; anything
  outside the 50 states and DC (territories) is dropped here.
  """
  def county_index do
    from(c in "county_population", select: {c.fips, c.name, c.state, c.population})
    |> Repo.all()
    |> Enum.reduce({%{}, %{}}, fn {fips, name, state_name, population}, {counties, lookup} ->
      case @state_abbreviations[String.downcase(state_name)] do
        nil ->
          {counties, lookup}

        state ->
          {
            Map.put(counties, fips, %{population: population, state: state}),
            Map.put(lookup, {state, index_key(name)}, fips)
          }
      end
    end)
  end

  @doc """
  `%{fips => [{bus_id, share}]}` — each county's population split across its
  nearest buses, shares summing to 1.

  This is `LoadEstimator.population_per_bus/0` kept per-county instead of
  aggregated, over the same bus universe (PQ, geolocated) narrowed to buses
  that actually carry a load. Same 25-neighbor / 75 km / inverse-distance rule,
  so BTM capacity lands exactly where the load it offsets landed.
  """
  def bus_shares do
    %{rows: rows} =
      Repo.query!(
        """
        WITH nearest AS (
          SELECT c.fips, c.id AS county_id, n.id AS bus_id, n.dist_m,
                 ROW_NUMBER() OVER (PARTITION BY c.id ORDER BY n.dist_m) AS rn
          FROM county_population c
          JOIN LATERAL (
            SELECT b.id,
                   ST_Distance(b.coordinates::geography, c.coordinates::geography) AS dist_m
            FROM buses b
            WHERE b.bus_type = 1 AND b.coordinates IS NOT NULL
              AND EXISTS (
                SELECT 1 FROM loads l
                WHERE l.bus_id = b.id AND l.status = 'in_service'
              )
            ORDER BY b.coordinates <-> c.coordinates
            LIMIT 25
          ) n ON true
        ),
        kept AS (
          SELECT * FROM nearest WHERE rn = 1 OR dist_m <= 75000
        )
        SELECT fips, bus_id,
               (1.0 / GREATEST(dist_m, 1000))
                 / SUM(1.0 / GREATEST(dist_m, 1000)) OVER (PARTITION BY county_id) AS share
        FROM kept
        """,
        [],
        timeout: :infinity
      )

    rows
    |> Enum.group_by(fn [fips, _bus_id, _share] -> fips end, fn [_fips, bus_id, share] ->
      {bus_id, share}
    end)
  end

  # ------------------------------------------------------------------- parsing

  @doc """
  Parse the Net_Metering **States** sheet (3 stacked header rows) into
  `[%{utility_id, state, sector, capacity_mw}]`.
  """
  def parse_net_metering(csv) when is_binary(csv) do
    parse_capacity_sheet(csv, 3, fn sector_label ->
      [{:prefix, "photovoltaic"}, "capacity mw", sector_label]
    end)
  end

  @doc """
  Parse the Non_Net_Metering_Distributed **States_ Utility Level** sheet
  (2 stacked header rows) into `[%{utility_id, state, sector, capacity_mw}]`.
  """
  def parse_non_net_metering(csv) when is_binary(csv) do
    parse_capacity_sheet(csv, 2, fn sector_label ->
      [{:prefix, "photovoltaic"}, sector_label]
    end)
  end

  defp parse_capacity_sheet(csv, header_rows, path_fun) do
    case EIA861Parser.parse_string(csv, skip_headers: false) do
      rows when length(rows) > header_rows ->
        {headers, data} = Enum.split(rows, header_rows)
        filled = Enum.map(headers, &forward_fill/1)
        fields = List.last(filled)

        with {:ok, identity} <- resolve_identity(fields),
             {:ok, sectors} <- resolve_sectors(filled, path_fun) do
          {:ok, capacity_rows(data, identity, sectors)}
        end

      _ ->
        {:error, :sheet_too_short}
    end
  end

  defp resolve_identity(fields) do
    resolve_all(%{
      state: fn -> find_field(fields, "state") end,
      utility_id: fn -> find_field(fields, "utility number") end
    })
  end

  defp resolve_sectors(filled, path_fun) do
    @sector_columns
    |> Map.new(fn {sector, label} ->
      {sector, fn -> find_path(filled, path_fun.(String.downcase(label))) end}
    end)
    |> resolve_all()
  end

  defp resolve_all(resolvers) do
    Enum.reduce_while(resolvers, {:ok, %{}}, fn {name, resolver}, {:ok, acc} ->
      case resolver.() do
        {:ok, index} -> {:cont, {:ok, Map.put(acc, name, index)}}
        {:error, reason} -> {:halt, {:error, {name, reason}}}
      end
    end)
  end

  defp capacity_rows(data, identity, sectors) do
    for row <- data,
        utility_id = row |> Enum.at(identity.utility_id) |> normalize_id(),
        utility_id != "",
        utility_id != @adjustment_utility,
        state = row |> Enum.at(identity.state) |> to_string() |> String.trim() |> String.upcase(),
        MapSet.member?(@state_codes, state),
        {sector, index} <- sectors,
        capacity = row |> Enum.at(index) |> parse_number(),
        capacity > 0.0 do
      %{utility_id: utility_id, state: state, sector: sector, capacity_mw: capacity}
    end
  end

  @doc """
  Turn the service territory's county NAMES into FIPS codes.

  Returns `{%{{utility_id, state} => [fips]}, unmatched_names}`.
  """
  def resolve_territories(name_territories, lookup) do
    Enum.reduce(name_territories, {%{}, MapSet.new()}, fn {{utility_id, state}, names},
                                                          {acc, unmatched} ->
      {fips_list, unmatched} =
        Enum.reduce(names, {[], unmatched}, fn name, {fips_list, unmatched} ->
          case match_county(lookup, state, name) do
            nil -> {fips_list, MapSet.put(unmatched, {state, name})}
            fips -> {[fips | fips_list], unmatched}
          end
        end)

      acc =
        case Enum.uniq(fips_list) do
          [] -> acc
          list -> Map.put(acc, {utility_id, state}, list)
        end

      {acc, unmatched}
    end)
  end

  defp match_county(lookup, state, name) do
    name
    |> lookup_keys()
    |> Enum.find_value(fn key -> Map.get(lookup, {state, key}) end)
  end

  @doc """
  Parse the Service_Territory **Counties_States** sheet (1 header row) into
  `%{{utility_id, state} => [county_name]}`.
  """
  def parse_service_territory(csv) when is_binary(csv) do
    case EIA861Parser.parse_string(csv, skip_headers: false) do
      [header | data] ->
        fields = forward_fill(header)

        with {:ok, columns} <-
               resolve_all(%{
                 utility_id: fn -> find_field(fields, "utility number") end,
                 state: fn -> find_field(fields, "state") end,
                 county: fn -> find_field(fields, "county") end
               }) do
          territories =
            data
            |> Enum.reduce(%{}, fn row, acc ->
              utility_id = row |> Enum.at(columns.utility_id) |> normalize_id()

              state =
                row |> Enum.at(columns.state) |> to_string() |> String.trim() |> String.upcase()

              county = row |> Enum.at(columns.county) |> to_string() |> String.trim()

              if utility_id == "" or state == "" or county == "" do
                acc
              else
                Map.update(acc, {utility_id, state}, [county], &[county | &1])
              end
            end)

          {:ok, territories}
        end

      _ ->
        {:error, :sheet_too_short}
    end
  end

  # -------------------------------------------------------------- header paths

  # Merged header cells carry their value in the first column and blanks after,
  # so a group label has to be carried rightwards before a path can match.
  defp forward_fill(row) do
    row
    |> Enum.map_reduce("", fn cell, last ->
      value = cell |> to_string() |> String.trim() |> String.replace(~r/\s+/, " ")
      carried = if value == "", do: last, else: value
      {carried, carried}
    end)
    |> elem(0)
  end

  # Exact match on the leaf header row, for the identity columns that sit
  # outside any measure group.
  defp find_field(fields, name) do
    fields
    |> Enum.with_index()
    |> Enum.filter(fn {value, _i} -> String.downcase(value) == name end)
    |> case do
      [{_value, index}] -> {:ok, index}
      [] -> {:error, {:column_not_found, name}}
      many -> {:error, {:ambiguous_column, name, Enum.map(many, &elem(&1, 1))}}
    end
  end

  # Match every header row at once. "Capacity MW / Residential" repeats under
  # four technology groups on the net-metering sheet, so a leaf-only match
  # would silently read Wind.
  defp find_path(filled_rows, path) do
    width = filled_rows |> Enum.map(&length/1) |> Enum.min()

    0..(width - 1)
    |> Enum.filter(fn column ->
      filled_rows
      |> Enum.take(-length(path))
      |> Enum.zip(path)
      |> Enum.all?(fn {row, matcher} -> match_header?(Enum.at(row, column), matcher) end)
    end)
    |> case do
      [index] -> {:ok, index}
      [] -> {:error, {:path_not_found, path}}
      many -> {:error, {:ambiguous_path, path, many}}
    end
  end

  defp match_header?(value, {:prefix, prefix}),
    do: value |> to_string() |> String.downcase() |> String.starts_with?(prefix)

  defp match_header?(value, expected),
    do: value |> to_string() |> String.downcase() == expected

  # ---------------------------------------------------------- county matching

  @doc """
  The index key for a county name as the Census writes it: diacritics folded,
  county-type suffix removed, and a flag for Virginia-style independent cities.

      iex> PowerModel.Ingestion.EIA.Form861.index_key("Doña Ana County")
      {"donaana", false}
      iex> PowerModel.Ingestion.EIA.Form861.index_key("Roanoke city")
      {"roanoke", true}
  """
  def index_key(name) do
    normalized = normalize_name(name)

    case strip_county_suffix(normalized) do
      {:ok, base} -> {squeeze(base), false}
      :none -> independent_city_key(normalized)
    end
  end

  @doc """
  Candidate keys for a county name as EIA-861 writes it, most specific first.

  861 drops the type word, which makes "Roanoke City" (the independent city)
  and "James City" (James City *County*) look alike. Trying the independent
  city reading first and the literal reading second resolves both, and a bare
  base catches "Bedford City", a city that reverted to a town and now exists
  only as Bedford County.
  """
  def lookup_keys(name) do
    normalized = normalize_name(name)

    literal =
      case strip_county_suffix(normalized) do
        {:ok, base} -> squeeze(base)
        :none -> squeeze(normalized)
      end

    case independent_city_key(normalized) do
      {city_base, true} -> Enum.uniq([{city_base, true}, {literal, false}, {city_base, false}])
      _ -> [{literal, false}]
    end
  end

  defp independent_city_key(normalized) do
    case String.split(normalized, " ") do
      parts when length(parts) > 1 ->
        if List.last(parts) == "city" do
          {parts |> Enum.drop(-1) |> Enum.join(" ") |> squeeze(), true}
        else
          {squeeze(normalized), false}
        end

      _ ->
        {squeeze(normalized), false}
    end
  end

  defp strip_county_suffix(normalized) do
    Enum.find_value(@county_suffixes, :none, fn suffix ->
      if String.ends_with?(normalized, " " <> suffix) do
        {:ok, String.replace_suffix(normalized, " " <> suffix, "")}
      end
    end)
  end

  # NFD splits "ñ" into "n" + a combining tilde; dropping everything outside
  # ASCII then leaves "n", so EIA's "Dona Ana" reaches Census's "Doña Ana".
  defp normalize_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\x00-\x7f]/u, "")
    |> String.replace(~r/\s+/, " ")
  end

  defp squeeze(value) do
    value
    |> String.replace(~r/[^a-z0-9]/, "")
    |> String.replace_prefix("saint", "st")
  end

  # ------------------------------------------------------------ file discovery

  defp locate_files(data_dir) do
    with {:ok, dir} <- extracted_dir(data_dir) do
      required = %{
        net_metering: {"Net_Metering", "States"},
        non_net_metering: {"Non_Net_Metering_Distributed", "States_"},
        service_territory: {"Service_Territory", "Counties_States"}
      }

      found =
        Map.new(required, fn {key, {file_prefix, sheet_prefix}} ->
          {key, {find_workbook(dir, file_prefix), sheet_prefix}}
        end)

      case Enum.filter(found, fn {_key, {path, _sheet}} -> is_nil(path) end) do
        [] -> {:ok, found}
        missing -> {:error, {:workbooks_not_found, Enum.map(missing, &elem(&1, 0))}}
      end
    end
  end

  # The 861 ships as one zip of 20 workbooks. Extract once into a temp dir
  # unless the workbooks are already sitting loose in data_dir.
  defp extracted_dir(data_dir) do
    cond do
      find_workbook(data_dir, "Net_Metering") ->
        {:ok, data_dir}

      zip = find_zip(data_dir) ->
        target = Path.join(System.tmp_dir!(), "eia861_#{:erlang.phash2(zip)}")
        File.mkdir_p!(target)

        case :zip.extract(String.to_charlist(zip), [{:cwd, String.to_charlist(target)}]) do
          {:ok, _files} -> {:ok, target}
          {:error, reason} -> {:error, {:unzip_failed, reason}}
        end

      true ->
        {:error, {:no_eia861_data, data_dir}}
    end
  end

  defp find_zip(data_dir) do
    data_dir
    |> ls()
    |> Enum.filter(&(&1 =~ ~r/^f861.*\.zip$/i))
    |> Enum.sort()
    |> List.last()
    |> case do
      nil -> nil
      name -> Path.join(data_dir, name)
    end
  end

  defp find_workbook(dir, prefix) do
    dir
    |> ls()
    |> Enum.filter(&(String.starts_with?(&1, prefix) and String.ends_with?(&1, ".xlsx")))
    |> Enum.sort()
    |> List.last()
    |> case do
      nil -> nil
      name -> Path.join(dir, name)
    end
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  defp read_capacity(files) do
    {net_path, net_sheet} = files.net_metering
    {non_path, non_sheet} = files.non_net_metering

    with {:ok, net_csv} <- extract_sheet_to_csv(net_path, net_sheet),
         {:ok, non_csv} <- extract_sheet_to_csv(non_path, non_sheet),
         {:ok, net_rows} <- parse_net_metering(net_csv),
         {:ok, non_rows} <- parse_non_net_metering(non_csv) do
      IO.puts(
        "  Net-metered PV: #{mw(net_rows)} MW  |  non-net-metered distributed PV: #{mw(non_rows)} MW"
      )

      {:ok, net_rows ++ non_rows}
    end
  end

  defp read_territories(files) do
    {path, sheet} = files.service_territory

    with {:ok, csv} <- extract_sheet_to_csv(path, sheet),
         {:ok, names_by_utility} <- parse_service_territory(csv) do
      {:ok, names_by_utility}
    end
  end

  defp mw(rows), do: rows |> Enum.map(& &1.capacity_mw) |> Enum.sum() |> Float.round(0)

  @doc """
  Dump one sheet of an xlsx to CSV text via openpyxl, the same shell-out
  `EPA.EGrid` uses (Elixir has no xlsx reader and EIA ships nothing else).
  Matches the sheet name exactly first, then by prefix.
  """
  def extract_sheet_to_csv(xlsx_path, sheet_prefix) do
    script = """
    import openpyxl, csv, io, sys
    wb = openpyxl.load_workbook(sys.argv[1], read_only=True, data_only=True)
    wanted = sys.argv[2]
    sheet = None
    if wanted in wb.sheetnames:
        sheet = wb[wanted]
    else:
        for name in wb.sheetnames:
            if name.startswith(wanted):
                sheet = wb[name]
                break
    if sheet is None:
        sys.exit(2)
    out = io.StringIO()
    writer = csv.writer(out)
    for row in sheet.iter_rows(values_only=True):
        writer.writerow([str(c) if c is not None else '' for c in row])
    sys.stdout.write(out.getvalue())
    wb.close()
    """

    case System.cmd("python3", ["-c", script, xlsx_path, sheet_prefix], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, code} ->
        {:error, {:sheet_extraction_failed, xlsx_path, sheet_prefix, code, output}}
    end
  end

  defp normalize_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace_suffix(".0", "")
  end

  # EIA writes withheld and not-applicable cells as ".".
  defp parse_number(nil), do: 0.0
  defp parse_number(value) when is_number(value), do: value * 1.0

  defp parse_number(value) when is_binary(value) do
    case value |> String.trim() |> String.replace(",", "") |> Float.parse() do
      {number, _rest} -> number
      :error -> 0.0
    end
  end

  defp print_report(report) do
    IO.puts("  BTM solar capacity: #{Float.round(report.total_mw, 0)} MW parsed")
    IO.puts("    allocated to buses: #{Float.round(report.allocated_mw, 0)} MW")

    IO.puts(
      "    via state-level fallback (unmatched counties): " <>
        "#{Float.round(report.state_fallback_mw, 0)} MW"
    )

    IO.puts("    dropped, no service territory: #{Float.round(report.no_territory_mw, 0)} MW")
    IO.puts("    dropped, county reaches no bus: #{Float.round(report.no_bus_mw, 0)} MW")

    IO.puts(
      "    dropped, bus share below the #{@min_capacity_mw} MW row floor: " <>
        "#{Float.round(report.below_floor_mw, 3)} MW"
    )

    IO.puts(
      "    written: #{Float.round(report.written_mw, 1)} MW over #{report.rows_inserted} rows"
    )
  end
end
