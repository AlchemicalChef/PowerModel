defmodule PowerModel.Ingestion.EIA.HourlyGrid do
  @moduledoc """
  Ingest hourly grid operations data from the EIA API (Form EIA-930).

  Downloads hourly demand, generation, interchange, and generation-by-fuel-type
  data for all US balancing authorities. Data available from 2019-01-01 onward.

  Uses the EIA Open Data API v2:
    https://api.eia.gov/v2/electricity/rto/

  The DEMO_KEY works but is rate-limited. Set EIA_API_KEY env var for production use.
  """

  require Logger

  alias PowerModel.Repo
  alias PowerModel.Grid.{HourlyLoadProfile, HourlyGenerationMix}
  import Ecto.Query

  @base_url "https://api.eia.gov/v2/electricity/rto"
  @page_size 5000
  @request_delay 500

  @major_bas ~w(
    PJM MISO ERCO NYIS ISNE CISO SWPP SOCO TVA DUK FPL BPAT
    WACM PSCO PACE NEVP SRP APS LDWP TIDC WALC PNM EPE AECI
    AVA DOPD GCPD CHPD PSEI TPWR PACW SCL BANC IID PGE IPCO
    NWMT GVL FMPP JEA SEC SC TAL TEC NSB FPC SCEG CPLE CPLW
    LGEE OVEC EEI GRID SPA SEPA HST WWA GWA YAD
  )

  @regions ~w(US48 CAL TEX NW SE SW CENT MIDW MIDA NE NY FLA TEN)

  @doc """
  Ingest hourly demand/generation/interchange for all major BAs.

  Options:
    - `:start` — start date string, default "2025-01-01T00"
    - `:end` — end date string, default current date
    - `:bas` — list of BA codes, default all major BAs + regions
    - `:api_key` — EIA API key, default DEMO_KEY
  """
  def ingest_demand(opts \\ []) do
    api_key = resolve_api_key(opts)
    start_date = Keyword.get(opts, :start, "2025-01-01T00")
    end_date = Keyword.get(opts, :end, nil)
    bas = Keyword.get(opts, :bas, @major_bas ++ @regions)

    Logger.info("Ingesting EIA hourly demand data for #{length(bas)} BAs from #{start_date}...")

    results = Enum.map(bas, fn ba_code ->
      Logger.info("  Fetching demand for #{ba_code}...")
      fetch_and_store_demand(ba_code, api_key, start_date, end_date)
    end)

    total = Enum.sum(results)
    Logger.info("EIA hourly demand ingestion complete: #{total} records")
    {:ok, total}
  end

  @doc """
  Ingest hourly generation by fuel type for major BAs.
  """
  def ingest_generation_mix(opts \\ []) do
    api_key = resolve_api_key(opts)
    start_date = Keyword.get(opts, :start, "2025-01-01T00")
    end_date = Keyword.get(opts, :end, nil)
    bas = Keyword.get(opts, :bas, @major_bas ++ @regions)

    Logger.info("Ingesting EIA hourly generation mix for #{length(bas)} BAs from #{start_date}...")

    results = Enum.map(bas, fn ba_code ->
      Logger.info("  Fetching generation mix for #{ba_code}...")
      fetch_and_store_generation_mix(ba_code, api_key, start_date, end_date)
    end)

    total = Enum.sum(results)
    Logger.info("EIA generation mix ingestion complete: #{total} records")
    {:ok, total}
  end

  @doc """
  Ingest a representative week of data (for quick testing).
  Downloads one summer week and one winter week for the 3 interconnection-level BAs.
  """
  def ingest_sample(opts \\ []) do
    api_key = resolve_api_key(opts)
    sample_bas = ~w(PJM ERCO CISO MISO SWPP NYIS ISNE TVA BPAT US48)

    Logger.info("Ingesting sample EIA data for #{length(sample_bas)} BAs...")

    weeks = [
      {"Summer", "2025-07-14T00", "2025-07-20T23"},
      {"Winter", "2025-01-13T00", "2025-01-19T23"},
      {"Spring", "2025-04-14T00", "2025-04-20T23"},
      {"Fall", "2025-10-13T00", "2025-10-19T23"}
    ]

    totals = Enum.map(weeks, fn {label, start_d, end_d} ->
      Logger.info("  #{label} week (#{start_d} to #{end_d})...")
      week_total = Enum.reduce(sample_bas, 0, fn ba, acc ->
        n = fetch_and_store_demand(ba, api_key, start_d, end_d)
        Process.sleep(@request_delay)
        m = fetch_and_store_generation_mix(ba, api_key, start_d, end_d)
        Process.sleep(@request_delay)
        Logger.info("    #{ba}: #{n} demand + #{m} gen mix records")
        acc + n + m
      end)
      Logger.info("  #{label}: #{week_total} records")
      week_total
    end)

    total = Enum.sum(totals)
    Logger.info("Sample ingestion complete: #{total} total records")
    {:ok, total}
  end

  defp fetch_and_store_demand(ba_code, api_key, start_date, end_date) do
    params = base_params(api_key, start_date, end_date) ++ [
      {"facets[respondent][]", ba_code}
    ]

    records = fetch_all_pages("#{@base_url}/region-data/data/", params)

    by_period = Enum.group_by(records, & &1["period"])

    entries = Enum.map(by_period, fn {period, rows} ->
      ba_name = get_in(List.first(rows), ["respondent-name"])
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      metrics = Map.new(rows, fn r -> {r["type"], parse_value(r["value"])} end)

      %{
        ba_code: ba_code,
        ba_name: ba_name,
        period: parse_period(period),
        demand_mw: metrics["D"],
        generation_mw: metrics["NG"],
        interchange_mw: metrics["TI"],
        forecast_mw: metrics["DF"],
        inserted_at: now,
        updated_at: now
      }
    end)
    |> Enum.filter(fn e -> e.period != nil end)

    entries
    |> Enum.chunk_every(500)
    |> Enum.each(fn batch ->
      Repo.insert_all(HourlyLoadProfile, batch,
        on_conflict: {:replace, [:demand_mw, :generation_mw, :interchange_mw, :forecast_mw, :updated_at]},
        conflict_target: [:ba_code, :period]
      )
    end)

    length(entries)
  end

  defp fetch_and_store_generation_mix(ba_code, api_key, start_date, end_date) do
    params = base_params(api_key, start_date, end_date) ++ [
      {"facets[respondent][]", ba_code}
    ]

    records = fetch_all_pages("#{@base_url}/fuel-type-data/data/", params)

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries = Enum.map(records, fn r ->
      %{
        ba_code: ba_code,
        period: parse_period(r["period"]),
        fuel_type: r["fueltype"],
        generation_mw: parse_value(r["value"]),
        inserted_at: now,
        updated_at: now
      }
    end)
    |> Enum.filter(fn e -> e.period != nil and e.fuel_type != nil end)

    entries
    |> Enum.chunk_every(500)
    |> Enum.each(fn batch ->
      Repo.insert_all(HourlyGenerationMix, batch,
        on_conflict: {:replace, [:generation_mw, :updated_at]},
        conflict_target: [:ba_code, :period, :fuel_type]
      )
    end)

    length(entries)
  end

  defp base_params(api_key, start_date, end_date) do
    params = [
      {"api_key", api_key},
      {"frequency", "hourly"},
      {"data[0]", "value"},
      {"sort[0][column]", "period"},
      {"sort[0][direction]", "asc"},
      {"length", to_string(@page_size)}
    ]

    params = if start_date, do: params ++ [{"start", start_date}], else: params
    params = if end_date, do: params ++ [{"end", end_date}], else: params
    params
  end

  defp fetch_all_pages(url, params) do
    fetch_all_pages(url, params, 0, [])
  end

  defp fetch_all_pages(url, params, offset, acc) do
    page_params = params ++ [{"offset", to_string(offset)}]

    case fetch_page(url, page_params) do
      {:ok, data, total} ->
        acc = acc ++ data
        if offset + @page_size < total do
          Process.sleep(@request_delay)
          fetch_all_pages(url, params, offset + @page_size, acc)
        else
          acc
        end

      {:error, :rate_limited} ->
        Logger.warning("Rate limited, waiting 30s before retry...")
        Process.sleep(30_000)
        fetch_all_pages(url, params, offset, acc)

      {:error, reason} ->
        Logger.warning("EIA API error at offset #{offset}: #{inspect(reason)}")
        acc
    end
  end

  defp fetch_page(url, params) do
    query = URI.encode_query(params)
    full_url = "#{url}?#{query}"

    case Req.get(full_url, receive_timeout: 30_000, retry: false) do
      {:ok, %{status: 200, body: %{"response" => resp}}} ->
        data = resp["data"] || []
        total = parse_int(resp["total"]) || 0
        {:ok, data, total}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, err} ->
        {:error, err}
    end
  end

  defp parse_period(nil), do: nil
  defp parse_period(period_str) when is_binary(period_str) do
    case NaiveDateTime.from_iso8601(period_str <> ":00:00") do
      {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
      _ -> nil
    end
  end

  defp parse_value(nil), do: nil
  defp parse_value(v) when is_number(v), do: v * 1.0
  defp parse_value(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(v) when is_integer(v), do: v
  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp resolve_api_key(opts) do
    Keyword.get(opts, :api_key, nil) ||
      System.get_env("EIA_API_KEY") ||
      "DEMO_KEY"
  end

  @doc """
  Get summary statistics of ingested data.
  """
  def stats do
    load_count = Repo.aggregate(HourlyLoadProfile, :count)
    mix_count = Repo.aggregate(HourlyGenerationMix, :count)
    ba_count = Repo.one(from h in HourlyLoadProfile, select: count(h.ba_code, :distinct))

    earliest = Repo.one(from h in HourlyLoadProfile, select: min(h.period))
    latest = Repo.one(from h in HourlyLoadProfile, select: max(h.period))

    %{
      load_profile_records: load_count,
      generation_mix_records: mix_count,
      balancing_authorities: ba_count,
      earliest_period: earliest,
      latest_period: latest
    }
  end
end
