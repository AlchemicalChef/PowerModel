defmodule PowerModel.Ingestion.Epa.Cems do
  @moduledoc """
  Measured hourly unit operation from EPA's Clean Air Markets continuous
  emissions monitors (CEMS), read from the vendored CAMPD pulls in
  `data/vendored/` (see PROVENANCE.md there).

  CEMS is the one national dataset that reports what each fossil unit was
  ACTUALLY doing, hour by hour: gross load in MW per CAMD unit, keyed by ORIS
  facility id — which is the EIA plant id `PowerModel.Grid.Generator` already
  carries. `PowerModel.Dispatch` uses it to pin the fossil fleet to its
  measured operating point (ROADMAP C1) instead of inventing a merit order,
  which is what puts real stress on the real elements: the congestion score
  (REVIEW EXT-1/2) found the model's flows in the wrong places, and the
  blackout-size run (REVIEW EXT-3) found no cascade tail, both because the
  BA-fuel dispatch spreads generation too evenly.

  ## Conventions the data forces

  * **Hours are local STANDARD time year-round**, never DST. Verified
    empirically, not assumed: the TX gas fleet's 24 h shape correlates with
    EIA-930's ERCO gas column at r=0.992 under UTC-6, against 0.929 for UTC-5
    and 0.956 for UTC-7 (PROVENANCE.md). Each facility's standard offset is
    derived from its state plus a longitude/latitude override for the states a
    timezone boundary splits; plants within ~50 km of a jagged boundary may be
    read one hour off, which at fleet level is second-order.

  * **Gross load is GROSS** — station service included — while EIA-930
    generation is net. The dispatch therefore never treats a CEMS MW as a MW
    to serve: EIA-930 keeps the totals, CEMS supplies the SHAPE (which units,
    how hard, relative to each other).

  * A unit row with a blank gross load at an hour the file covers is a unit
    that was verifiably OFF, not missing data: the files carry a row for
    every unit-hour of the day. Absence of the whole facility from the file
    is what "unmeasured" means.
  """

  NimbleCSV.define(CemsCSV, separator: ",", escape: "\"")

  require Logger

  @vendored_dir Path.join(["data", "vendored"])
  @facilities_file "epa_camd_facilities_2024.csv"
  @hourly_prefix "epa_cems_hourly_"

  @cems_fuels ~w(coal natural_gas petroleum)

  @doc "The EIA-930 fuels CEMS can pin (the fossil fleet it monitors)."
  @spec fuels() :: [String.t()]
  def fuels, do: @cems_fuels

  @doc """
  Measured plant operation at a UTC hour: `%{plant_id => %{fuel => gross_mw}}`.

  `plant_id` is the ORIS/EIA plant id as a canonical integer-string; `fuel`
  is the EIA-930 fuel the unit's CAMD primary fuel maps to. A fuel present
  with `0.0` means every monitored unit of that fuel at the plant sat idle at
  that hour — a measurement, distinct from the plant being absent.

  Returns `%{}` when no vendored day covers the hour, so a caller needs no
  special case for hours outside the reference day.
  """
  @spec measured_at(DateTime.t()) :: %{optional(String.t()) => %{optional(String.t()) => float()}}
  def measured_at(%DateTime{} = utc_hour) do
    utc_hour = %{utc_hour | minute: 0, second: 0, microsecond: {0, 0}}
    key = {__MODULE__, DateTime.to_unix(utc_hour)}

    case :persistent_term.get(key, :miss) do
      :miss ->
        measured = load_hour(utc_hour)
        :persistent_term.put(key, measured)
        measured

      measured ->
        measured
    end
  end

  defp load_hour(utc_hour) do
    offsets = facility_offsets()

    # Per facility, the (local date, local hour) that IS the requested UTC
    # hour under that facility's standard offset.
    wanted =
      Map.new(offsets, fn {fid, offset} ->
        local = DateTime.add(utc_hour, offset * 3600, :second)
        {fid, {Date.to_iso8601(DateTime.to_date(local)), local.hour}}
      end)

    hourly_files()
    |> Enum.reduce(%{}, fn path, acc -> scan_file(path, wanted, acc) end)
    |> tap(fn m ->
      if map_size(m) == 0 do
        Logger.warning(
          "CEMS: no vendored day covers #{DateTime.to_iso8601(utc_hour)}; dispatch runs unpinned"
        )
      end
    end)
  end

  defp scan_file(path, wanted, acc) do
    path
    |> File.stream!(read_ahead: 512 * 1024)
    |> CemsCSV.parse_stream()
    |> Enum.reduce(acc, fn [_state, fid, _unit, date, hour, _op, gross, fuel_type], acc ->
      case Map.get(wanted, fid) do
        {^date, local_hour} ->
          if String.to_integer(hour) == local_hour do
            add_measurement(acc, fid, fuel_class(fuel_type), parse_mw(gross))
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  defp add_measurement(acc, _fid, nil, _mw), do: acc

  defp add_measurement(acc, fid, fuel, mw) do
    Map.update(acc, fid, %{fuel => mw}, fn fuels ->
      Map.update(fuels, fuel, mw, &(&1 + mw))
    end)
  end

  # Facility id => standard UTC offset (hours, negative west), from the
  # vendored attributes file. Ids canonicalised the same way plant ids are.
  defp facility_offsets do
    path = Path.join(@vendored_dir, @facilities_file)

    path
    |> File.stream!(read_ahead: 512 * 1024)
    |> CemsCSV.parse_stream()
    |> Enum.reduce(%{}, fn [state, fid, _unit, lat, lon, _fuel, _status, _gens], acc ->
      Map.put_new_lazy(acc, fid, fn ->
        standard_offset(state, parse_mw(lat), parse_mw(lon))
      end)
    end)
  end

  defp hourly_files do
    @vendored_dir
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, @hourly_prefix))
    |> Enum.sort()
    |> Enum.map(&Path.join(@vendored_dir, &1))
  end

  @doc """
  Canonical plant id: the integer-string both sides of the ORIS/EIA join use
  (`"0123"` and `"123"` are the same plant). `nil` for anything non-numeric.
  """
  @spec plant_id(term()) :: String.t() | nil
  def plant_id(value) do
    case value |> to_string() |> String.trim() |> Integer.parse() do
      {n, ""} -> Integer.to_string(n)
      _ -> nil
    end
  end

  # CAMD primary fuel -> the EIA-930 fuel column the unit's output is counted
  # in. Consistent with Dispatch's @fuel_codes (petroleum coke -> petroleum).
  # Process/other gas, wood and tires land in "other", which EIA-930 also
  # keeps outside its gas column, so they are left unpinned rather than
  # miscounted.
  defp fuel_class(fuel_type) do
    f = to_string(fuel_type)

    cond do
      f == "" -> nil
      String.contains?(f, "Coal") -> "coal"
      String.contains?(f, "Natural Gas") -> "natural_gas"
      String.contains?(f, "Oil") or String.contains?(f, "Diesel") -> "petroleum"
      String.contains?(f, "Coke") -> "petroleum"
      true -> nil
    end
  end

  defp parse_mw(""), do: 0.0

  defp parse_mw(value) do
    case Float.parse(value) do
      {mw, _} -> mw
      :error -> 0.0
    end
  end

  # Standard-time UTC offset by state, with longitude/latitude overrides for
  # the split states. Boundaries are approximate (county lines are jagged);
  # the cost of a miss is reading a boundary plant one hour off.
  @pacific ~w(WA OR CA NV)
  @mountain ~w(MT ID WY UT CO AZ NM)
  @central ~w(TX OK KS NE SD ND MN IA MO WI IL AR LA MS AL TN)

  defp standard_offset(state, lat, lon) do
    cond do
      state == "AK" -> -9
      state == "HI" -> -10
      state == "TX" and lon < -104.9 -> -7
      state == "ID" and lat > 45.5 -> -8
      state == "OR" and lon > -117.6 and lat < 44.5 -> -7
      state in ~w(ND SD NE KS) and lon < -101.5 -> -7
      state == "TN" and lon > -85.5 -> -5
      state == "FL" and lon < -85.5 -> -6
      state == "MI" and lon < -88.6 -> -6
      state == "KY" and lon < -86.0 -> -6
      state == "IN" and lon < -87.0 and (lat > 41.2 or lat < 38.6) -> -6
      state in @pacific -> -8
      state in @mountain -> -7
      state in @central -> -6
      true -> -5
    end
  end
end
