defmodule PowerModel.Ingestion.EIA.Form930 do
  @moduledoc """
  Ingest actual hourly electricity demand per balancing authority from EIA-930
  bulk balance CSV files (Hourly Electric Grid Monitor).

  Download the six-month BALANCE files from
  https://www.eia.gov/electricity/gridmonitor (Download Data -> bulk files),
  e.g. `EIA930_BALANCE_2024_Jan_Jun.csv`, into `data/`.

  Files are large (~100-200 MB); parsing is streamed end to end. Rows are
  upserted on `{balancing_authority_id, timestamp_utc}`, so re-ingesting a
  re-downloaded file refreshes values (EIA revises data) without duplicates.

  Adjusted demand is preferred over raw demand when present; rows without a
  parseable demand value (e.g. generation-only BAs) are skipped.
  """

  NimbleCSV.define(EIA930Parser, separator: ",", escape: "\"")

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Demand.BADemandHour
  alias PowerModel.Grid.BalancingAuthority

  @batch_size 1000

  # Column name candidates across file vintages, in preference order.
  # 2024+ bulk files publish EIA's cleaned values as "(Imputed)"; older
  # vintages used "(Adjusted)". Either is preferred over the raw column.
  @ba_columns ["Balancing Authority"]
  @utc_columns ["UTC Time at End of Hour", "UTC time at end of hour"]
  @demand_adjusted_columns [
    "Demand (MW) (Imputed)",
    "Demand (MW) (Adjusted)",
    "Adjusted Demand (MW)"
  ]
  @demand_columns ["Demand (MW)"]
  @net_gen_adjusted_columns [
    "Net Generation (MW) (Imputed)",
    "Net Generation (MW) (Adjusted)",
    "Adjusted Net Generation (MW)"
  ]
  @net_gen_columns ["Net Generation (MW)"]
  @interchange_columns ["Total Interchange (MW) (Imputed)", "Total Interchange (MW)"]

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
  Returns `{:ok, upserted_row_count}`.
  """
  def ingest_file(csv_path) do
    ba_codes = load_or_create_ba_codes()

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

        case parse_row(row, columns, codes) do
          nil -> {[], {columns, codes}}
          entry -> {[entry], {columns, codes}}
        end
    end)
    |> Stream.chunk_every(@batch_size)
    |> Enum.reduce(0, fn batch, count ->
      {n, _} =
        Repo.insert_all(BADemandHour, batch,
          on_conflict:
            {:replace, [:demand_mw, :net_generation_mw, :total_interchange_mw, :updated_at]},
          conflict_target: [:balancing_authority_id, :timestamp_utc]
        )

      count + n
    end)
    |> then(&{:ok, &1})
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Header resolution
  # ---------------------------------------------------------------------------

  defp resolve_columns(header) do
    find = fn candidates -> Enum.find_value(candidates, &index_of(header, &1)) end

    ba_idx = find.(@ba_columns)
    utc_idx = find.(@utc_columns)
    demand_adj_idx = find.(@demand_adjusted_columns)
    demand_idx = find.(@demand_columns)

    if ba_idx && utc_idx && (demand_adj_idx || demand_idx) do
      {:ok,
       %{
         ba: ba_idx,
         utc: utc_idx,
         demand_adjusted: demand_adj_idx,
         demand: demand_idx,
         net_gen_adjusted: find.(@net_gen_adjusted_columns),
         net_gen: find.(@net_gen_columns),
         interchange: find.(@interchange_columns)
       }}
    else
      {:error, %{missing: missing_columns(ba_idx, utc_idx, demand_adj_idx || demand_idx),
                 header: header}}
    end
  end

  defp index_of(header, name) do
    Enum.find_index(header, &(String.trim(&1) == name))
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

  defp parse_row(row, columns, ba_codes) do
    code = row |> at(columns.ba) |> String.trim()
    demand = first_number(row, [columns.demand_adjusted, columns.demand])
    timestamp = parse_utc(at(row, columns.utc))
    ba_id = Map.get(ba_codes, code)

    if code != "" and ba_id && demand && timestamp do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      %{
        balancing_authority_id: ba_id,
        timestamp_utc: timestamp,
        demand_mw: demand,
        net_generation_mw: first_number(row, [columns.net_gen_adjusted, columns.net_gen]),
        total_interchange_mw: first_number(row, [columns.interchange]),
        inserted_at: now,
        updated_at: now
      }
    end
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
  end
end
