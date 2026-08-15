defmodule PowerModel.Ingestion.EIA.Form930 do
  @moduledoc """
  Ingest actual hourly electricity demand and per-fuel net generation per
  balancing authority from EIA-930 bulk balance CSV files (Hourly Electric
  Grid Monitor).

  Download the six-month BALANCE files from
  https://www.eia.gov/electricity/gridmonitor (Download Data -> bulk files),
  e.g. `EIA930_BALANCE_2024_Jan_Jun.csv`, into `data/`.

  Files are large (~100-200 MB); parsing is streamed end to end. Demand rows
  are upserted on `{balancing_authority_id, timestamp_utc}` and fuel rows on
  `{ba_code, timestamp_utc, fuel}`, so re-ingesting a re-downloaded file
  refreshes values (EIA revises data) without duplicates.

  Adjusted demand is preferred over raw demand when present; rows without a
  parseable demand value (e.g. generation-only BAs) contribute no demand row —
  but their fuel rows are still ingested, because generation-only BAs still
  generate.

  ## Per-fuel columns

  EIA publishes 16 per-fuel net-generation columns per processing tier
  (raw / `(Imputed)` / `(Adjusted)`). They are collapsed onto the eight
  canonical fuels of `PowerModel.Demand.BAFuelHour` — the partition the
  generator fleet can actually be split along — and stored in `ba_fuel_hour`
  for `PowerModel.Dispatch`. Pumped storage, batteries, other/unknown storage,
  geothermal and other/unknown fuels all land in `"other"`.

  Two header names in the published files are malformed and defeat exact
  matching (both verified in `data/EIA930_BALANCE_2024_Jul_Dec.csv`):

    * `"...from Pumped Storage  (Adjusted)"` — two spaces before the suffix
    * `"...from Solar witho Integrated Battery Storage (Adjusted)"` — "witho"
      for "with", which a substring matcher also confuses with "without"

  The resolver collapses whitespace runs before comparing (catching the first)
  and carries the typo as an explicit alias of the with-battery solar column
  (catching the second), then compares for equality so "witho" can never
  shadow "without". Vintages that predate the storage split (single `Solar` /
  `Wind` columns) are read through the legacy aliases, which are consulted
  only when no split column is present.
  """

  NimbleCSV.define(EIA930Parser, separator: ",", escape: "\"")

  require Logger

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Demand.{BADemandHour, BAFuelHour}
  alias PowerModel.Grid.BalancingAuthority

  @batch_size 1000

  # Column name candidates across file vintages, in preference order. EVERY
  # candidate that exists is resolved, not just the first: a 2024 file carries
  # all three tiers of each series but leaves "(Imputed)" BLANK on rows that
  # needed no imputation, so binding to a single column silently yields nil
  # for the whole file (which is how `total_interchange_mw` came to be NULL
  # everywhere). Each row falls through the tiers until one holds a number.
  #
  # Adjusted leads: it is imputed AND reconciled so that
  # demand = net generation - interchange, the same tier the per-fuel columns
  # are read at, which is what makes generation minus load reproduce
  # interchange downstream.
  @ba_columns ["Balancing Authority"]
  @utc_columns ["UTC Time at End of Hour", "UTC time at end of hour"]
  @demand_columns [
    "Demand (MW) (Adjusted)",
    "Demand (MW) (Imputed)",
    "Demand (MW)"
  ]
  @net_gen_columns [
    "Net Generation (MW) (Adjusted)",
    "Net Generation (MW) (Imputed)",
    "Net Generation (MW)"
  ]
  @interchange_columns [
    "Total Interchange (MW) (Adjusted)",
    "Total Interchange (MW) (Imputed)",
    "Total Interchange (MW)"
  ]

  # Per-fuel net generation: {canonical_fuel, split_sources, legacy_sources}.
  # Each SOURCE is a list of spellings of one column (aliases exist only where
  # EIA published a malformed name); each source resolves independently and
  # all sources of a fuel are summed. Legacy sources are consulted only when
  # none of the split sources is present, so a file carrying both spellings
  # can never double-count.
  @fuel_prefix "Net Generation (MW) from "
  @fuel_sources [
    {"coal", [["Coal"]], []},
    {"natural_gas", [["Natural Gas"]], []},
    {"nuclear", [["Nuclear"]], []},
    {"petroleum", [["All Petroleum Products"]], [["Petroleum"]]},
    {"hydro", [["Hydropower Excluding Pumped Storage"]], [["Hydropower and Pumped Storage"]]},
    {"solar",
     [
       ["Solar without Integrated Battery Storage"],
       # "witho" is EIA's typo for "with" in the Adjusted tier
       ["Solar with Integrated Battery Storage", "Solar witho Integrated Battery Storage"]
     ], [["Solar"]]},
    {"wind",
     [
       ["Wind without Integrated Battery Storage"],
       ["Wind with Integrated Battery Storage"]
     ], [["Wind"]]},
    {"other",
     [
       ["Pumped Storage"],
       ["Battery Storage"],
       ["Other Energy Storage"],
       ["Unknown Energy Storage"],
       ["Geothermal"],
       ["Other Fuel Sources"],
       ["Unknown Fuel Sources"]
     ], []}
  ]

  # Processing tiers in preference order. EIA's Adjusted series is imputed AND
  # reconciled against demand/interchange, which is exactly the balance the
  # dispatch allocation needs.
  @fuel_tiers [" (Adjusted)", " (Imputed)", ""]

  @doc """
  Ingest EIA-930 balance data. `path` may be a directory (globs
  `EIA930_BALANCE_*.csv`) or a single CSV file.
  """
  def ingest(path) do
    files =
      cond do
        File.regular?(path) -> [path]
        File.dir?(path) -> Path.wildcard(Path.join(path, "EIA930_BALANCE_*.csv")) |> Enum.sort()
        true -> []
      end

    if files == [] do
      IO.puts("No EIA930_BALANCE_*.csv files found at #{path}")
      {:error, :no_files}
    else
      total =
        Enum.reduce(files, 0, fn file, acc ->
          IO.puts("Ingesting #{file}...")

          case ingest_file(file) do
            {:ok, count} ->
              IO.puts("  #{count} demand hours upserted.")
              acc + count

            {:error, reason} ->
              IO.puts("  Failed: #{inspect(reason)}")
              acc
          end
        end)

      report_coverage()
      {:ok, total}
    end
  end

  @doc """
  Stream-ingest a single EIA-930 BALANCE CSV file.

  Returns `{:ok, upserted_demand_row_count}`. Per-fuel rows are upserted into
  `ba_fuel_hour` in the same pass and reported separately (a file may carry
  many more fuel rows than demand rows, and generation-only BAs contribute
  fuel rows without a demand row).
  """
  def ingest_file(csv_path) do
    ba_codes = load_or_create_ba_codes()

    {demand_count, fuel_count} =
      csv_path
      |> File.stream!([:trim_bom])
      |> EIA930Parser.parse_stream(skip_headers: false)
      |> Stream.transform(nil, fn
        header, nil ->
          case resolve_columns(header) do
            {:ok, columns} -> {[], {columns, ba_codes}}
            {:error, reason} -> raise "EIA-930 header not recognized: #{inspect(reason)}"
          end

        row, {columns, codes} ->
          codes = ensure_ba_known(codes, row |> at(columns.ba) |> String.trim())
          {parse_entries(row, columns, codes), {columns, codes}}
      end)
      |> Stream.chunk_every(@batch_size)
      |> Enum.reduce({0, 0}, fn batch, {demand_count, fuel_count} ->
        {demand_entries, fuel_entries} = split_entries(batch)

        {demand_count + upsert_demand(demand_entries), fuel_count + upsert_fuel(fuel_entries)}
      end)

    if fuel_count > 0, do: IO.puts("  #{fuel_count} BA-fuel-hours upserted.")

    {:ok, demand_count}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp split_entries(batch) do
    {demand, fuel} =
      Enum.reduce(batch, {[], []}, fn
        {:demand, entry}, {demand, fuel} -> {[entry | demand], fuel}
        {:fuel, entry}, {demand, fuel} -> {demand, [entry | fuel]}
      end)

    {Enum.reverse(demand), Enum.reverse(fuel)}
  end

  defp upsert_demand([]), do: 0

  defp upsert_demand(entries) do
    {n, _} =
      Repo.insert_all(BADemandHour, entries,
        on_conflict:
          {:replace, [:demand_mw, :net_generation_mw, :total_interchange_mw, :updated_at]},
        conflict_target: [:balancing_authority_id, :timestamp_utc]
      )

    n
  end

  defp upsert_fuel([]), do: 0

  defp upsert_fuel(entries) do
    {n, _} =
      Repo.insert_all(BAFuelHour, entries,
        on_conflict: {:replace, [:net_generation_mw, :updated_at]},
        conflict_target: [:ba_code, :timestamp_utc, :fuel]
      )

    n
  end

  # ---------------------------------------------------------------------------
  # Header resolution
  # ---------------------------------------------------------------------------

  defp resolve_columns(header) do
    find = fn candidates -> Enum.find_value(candidates, &index_of(header, &1)) end
    find_all = fn candidates -> Enum.flat_map(candidates, &List.wrap(index_of(header, &1))) end

    ba_idx = find.(@ba_columns)
    utc_idx = find.(@utc_columns)
    demand_indices = find_all.(@demand_columns)

    if ba_idx && utc_idx && demand_indices != [] do
      {:ok,
       %{
         ba: ba_idx,
         utc: utc_idx,
         demand: demand_indices,
         net_gen: find_all.(@net_gen_columns),
         interchange: find_all.(@interchange_columns),
         fuels: resolve_fuel_columns(header)
       }}
    else
      {:error,
       %{missing: missing_columns(ba_idx, utc_idx, List.first(demand_indices)), header: header}}
    end
  end

  # `[{canonical_fuel, [source_column_indices]}]` for every fuel this vintage
  # carries. Fuels with no column at all are absent, so an old file without
  # per-fuel columns simply produces no fuel rows.
  defp resolve_fuel_columns(header) do
    Enum.flat_map(@fuel_sources, fn {fuel, split_sources, legacy_sources} ->
      case resolve_sources(header, split_sources) do
        [] ->
          case resolve_sources(header, legacy_sources) do
            [] -> []
            indices -> [{fuel, indices}]
          end

        indices ->
          [{fuel, indices}]
      end
    end)
  end

  # One index list per source, holding every processing tier that vintage
  # published (at most one column per tier — the aliases are spellings of the
  # same column). The row parser walks the list until a cell holds a number,
  # because EIA blanks a tier's cell on rows that tier did not touch.
  defp resolve_sources(header, sources) do
    Enum.flat_map(sources, fn aliases ->
      indices =
        for tier <- @fuel_tiers,
            idx = Enum.find_value(aliases, &index_of(header, @fuel_prefix <> &1 <> tier)),
            do: idx

      if indices == [], do: [], else: [indices]
    end)
  end

  # Whitespace-insensitive equality: EIA ships at least one column name with a
  # doubled space ("Pumped Storage  (Adjusted)"). Equality rather than a
  # substring test, so "Solar witho ..." cannot match "Solar without ...".
  defp index_of(header, name) do
    normalized = normalize_header(name)
    Enum.find_index(header, &(normalize_header(&1) == normalized))
  end

  defp normalize_header(name) do
    name |> String.trim() |> String.replace(~r/\s+/, " ")
  end

  defp missing_columns(ba_idx, utc_idx, demand_idx) do
    []
    |> then(&if(ba_idx, do: &1, else: ["Balancing Authority" | &1]))
    |> then(&if(utc_idx, do: &1, else: ["UTC Time at End of Hour" | &1]))
    |> then(&if(demand_idx, do: &1, else: ["Demand (MW)" | &1]))
  end

  # ---------------------------------------------------------------------------
  # Row parsing
  # ---------------------------------------------------------------------------

  # One CSV row yields at most one demand entry plus one fuel entry per fuel
  # the BA reported, tagged so a single stream feeds both tables.
  defp parse_entries(row, columns, ba_codes) do
    code = row |> at(columns.ba) |> String.trim()

    # EIA-930 timestamps the END of each hour; we store the hour BEGINNING so
    # a stored row at H means "consumption during (H, H+1]" lines up with
    # every lookup that truncates a requested time down to the hour. Fuel rows
    # use the identical convention.
    timestamp =
      case parse_utc(at(row, columns.utc)) do
        nil -> nil
        ts -> DateTime.add(ts, -3600, :second)
      end

    if code == "" or is_nil(timestamp) do
      []
    else
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      demand_entries(row, columns, ba_codes, code, timestamp, now) ++
        fuel_entries(row, columns, code, timestamp, now)
    end
  end

  defp demand_entries(row, columns, ba_codes, code, timestamp, now) do
    demand = first_number(row, columns.demand)
    ba_id = Map.get(ba_codes, code)

    if ba_id && demand do
      [
        {:demand,
         %{
           balancing_authority_id: ba_id,
           timestamp_utc: timestamp,
           demand_mw: demand,
           net_generation_mw: first_number(row, columns.net_gen),
           total_interchange_mw: first_number(row, columns.interchange),
           inserted_at: now,
           updated_at: now
         }}
      ]
    else
      []
    end
  end

  # A fuel is only recorded when at least one of its columns holds a number:
  # EIA leaves the cell blank for fuels a BA does not operate, and writing 0.0
  # there would claim coverage the file does not have.
  defp fuel_entries(row, columns, code, timestamp, now) do
    Enum.flat_map(columns.fuels, fn {fuel, sources} ->
      case Enum.flat_map(sources, fn candidates -> List.wrap(first_number(row, candidates)) end) do
        [] ->
          []

        values ->
          [
            {:fuel,
             %{
               ba_code: code,
               timestamp_utc: timestamp,
               fuel: fuel,
               net_generation_mw: Enum.sum(values),
               inserted_at: now,
               updated_at: now
             }}
          ]
      end
    end)
  end

  defp at(_row, nil), do: ""
  defp at(row, idx), do: Enum.at(row, idx, "")

  defp first_number(row, indices) do
    Enum.find_value(indices, fn
      nil -> nil
      idx -> parse_float(at(row, idx))
    end)
  end

  # Bulk files quote large numbers with thousands separators: "12,345"
  defp parse_float(val) do
    case val |> String.trim() |> String.replace(",", "") |> Float.parse() do
      {f, _} -> f
      :error -> nil
    end
  end

  # UTC column appears as ISO ("2024-07-15T21:00:00") in newer vintages or as
  # "7/15/2024 9:00:00 PM" in older ones. Using UTC sidesteps DST entirely.
  defp parse_utc(val) do
    val = String.trim(val)

    with :error <- parse_iso_utc(val) do
      parse_us_datetime(val)
    end
  end

  defp parse_iso_utc(val) do
    case NaiveDateTime.from_iso8601(val) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC") |> DateTime.truncate(:second)
      _ -> :error
    end
  end

  @us_datetime ~r/^(\d{1,2})\/(\d{1,2})\/(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM)?$/i

  defp parse_us_datetime(val) do
    case Regex.run(@us_datetime, val) do
      [_, month, day, year, hour, minute | rest] ->
        {second, meridiem} =
          case rest do
            [s, m] -> {s, m}
            [s] -> {s, nil}
            [] -> {"0", nil}
          end

        hour = to_24h(String.to_integer(hour), meridiem)

        with {:ok, naive} <-
               NaiveDateTime.new(
                 String.to_integer(year),
                 String.to_integer(month),
                 String.to_integer(day),
                 hour,
                 String.to_integer(minute),
                 String.to_integer(if(second == "", do: "0", else: second))
               ) do
          DateTime.from_naive!(naive, "Etc/UTC")
        else
          _ -> nil
        end

      nil ->
        nil
    end
  end

  defp to_24h(12, m) when is_binary(m) and byte_size(m) == 2 do
    if String.upcase(m) == "AM", do: 0, else: 12
  end

  defp to_24h(h, m) when is_binary(m) do
    if String.upcase(m) == "PM", do: h + 12, else: h
  end

  defp to_24h(h, nil), do: h

  # ---------------------------------------------------------------------------
  # BA code handling
  # ---------------------------------------------------------------------------

  defp load_or_create_ba_codes do
    Repo.all(from ba in BalancingAuthority, select: {ba.code, ba.id}) |> Map.new()
  end

  defp ensure_ba_known(codes, ""), do: codes

  # BAs present in EIA-930 but absent from eGRID (e.g. SEC) are created with
  # code-as-name so their demand still ingests; they scale nothing until buses
  # are mapped to them.
  defp ensure_ba_known(codes, code) do
    if Map.has_key?(codes, code) do
      codes
    else
      %BalancingAuthority{}
      |> BalancingAuthority.changeset(%{code: code, name: code})
      |> Repo.insert(on_conflict: :nothing)

      case Repo.one(from ba in BalancingAuthority, where: ba.code == ^code, select: ba.id) do
        nil -> codes
        id -> Map.put(codes, code, id)
      end
    end
  end

  defp report_coverage do
    rows = Repo.aggregate(BADemandHour, :count)

    bas_with_demand =
      Repo.one(
        from d in BADemandHour,
          select: count(d.balancing_authority_id, :distinct)
      )

    unmapped =
      Repo.all(
        from d in BADemandHour,
          join: ba in assoc(d, :balancing_authority),
          left_join: b in PowerModel.Grid.Bus,
          on: b.balancing_authority_id == ba.id,
          where: is_nil(b.id),
          select: ba.code,
          distinct: true
      )

    IO.puts("""
      EIA-930 coverage report:
        Demand hours stored:  #{rows}
        BAs with demand data: #{bas_with_demand}
        BAs with demand but no mapped buses: #{inspect(Enum.sort(unmapped))}
    """)

    report_fuel_coverage()
  end

  @doc """
  Print what the per-fuel table now covers: BAs, hours, and the energy each
  canonical fuel accounts for. Called at the end of `ingest/1`; useful on its
  own after a partial load.
  """
  def report_fuel_coverage do
    rows = Repo.aggregate(BAFuelHour, :count)

    if rows == 0 do
      IO.puts("      No per-fuel rows stored (file vintage carries no per-fuel columns).")
    else
      {bas, hours} =
        Repo.one(
          from f in BAFuelHour,
            select: {count(f.ba_code, :distinct), count(f.timestamp_utc, :distinct)}
        )

      by_fuel =
        Repo.all(
          from f in BAFuelHour,
            group_by: f.fuel,
            select: {f.fuel, count(f.id), sum(f.net_generation_mw), count(f.ba_code, :distinct)}
        )

      total_mwh = by_fuel |> Enum.map(fn {_, _, mwh, _} -> mwh || 0.0 end) |> Enum.sum()

      fuel_lines =
        by_fuel
        |> Enum.sort_by(fn {_, _, mwh, _} -> -(mwh || 0.0) end)
        |> Enum.map_join("\n", fn {fuel, n, mwh, ba_count} ->
          mwh = mwh || 0.0
          share = if total_mwh > 0.0, do: 100.0 * mwh / total_mwh, else: 0.0

          "        #{String.pad_trailing(fuel, 12)} " <>
            "#{String.pad_leading(Integer.to_string(n), 9)} rows  " <>
            "#{String.pad_leading(:erlang.float_to_binary(mwh / 1.0e6, decimals: 1), 8)} TWh  " <>
            "(#{:erlang.float_to_binary(share, decimals: 1)}%, #{ba_count} BAs)"
        end)

      IO.puts("""
        EIA-930 per-fuel coverage:
          Fuel-hours stored: #{rows}  (#{bas} BAs x #{hours} hours x #{length(by_fuel)} fuels)
          Total energy:      #{:erlang.float_to_binary(total_mwh / 1.0e6, decimals: 1)} TWh
      #{fuel_lines}
      """)
    end
  end
end
