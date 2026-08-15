defmodule PowerModel.Ingestion.EIA.Form923 do
  @moduledoc """
  Ingest capacity factors from EIA-923 generation data.

  The EIA-923 generation file carries one row per plant / prime-mover / fuel
  combination, so a plant usually spans SEVERAL rows. Net generation is
  aggregated across all of a plant's rows first, then a single plant-level
  capacity factor is computed against the plant's in-service capacity:

      CF = Σ net_generation_mwh / (Σ in-service nameplate MW × 8760)

  clamped to [0, 1], and written once per plant to the plant's in-service
  generators. (Computing a CF per row against whole-plant capacity and
  writing each one, as this module previously did, both understated the CF
  and left the final value dependent on row processing order.)

  The first CSV row must be the column-header row (export the XLSX schedule
  to CSV and remove any title rows above the headers). A file whose headers
  do not contain the plant-id / net-generation columns is reported loudly and
  ingests nothing.
  """

  NimbleCSV.define(EIA923Parser, separator: ",", escape: "\"")

  require Logger

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Grid.Generator

  @hours_in_year 8760.0

  @plant_id_headers ["Plant Id", "Plant Code", "Plant ID"]
  @net_gen_headers ["Net Generation (Megawatthours)"]

  def ingest(path) do
    gen_path = find_file(path, ~w(
      EIA923_Schedules_2_3_4_5_M_12_*.csv
      generation.csv
    ))

    if gen_path do
      gen_path
      |> File.stream!([:trim_bom])
      |> EIA923Parser.parse_stream(skip_headers: false)
      |> Enum.to_list()
      |> ingest_rows()
    else
      Logger.warning("EIA-923: no generation file found at #{path}; capacity factors not updated")
      {:error, :file_not_found}
    end
  end

  @doc """
  Aggregate parsed CSV rows (header row first) into per-plant capacity
  factors and write them. Returns `{:ok, plants_updated}` or
  `{:error, reason}`.
  """
  def ingest_rows([headers | data]) do
    # EIA headers sometimes wrap across lines inside the cell; collapse all
    # whitespace so "Net Generation\n(Megawatthours)" still matches.
    normalized = Enum.map(headers, &normalize_header/1)

    plant_idx = Enum.find_index(normalized, &(&1 in @plant_id_headers))
    net_gen_idx = Enum.find_index(normalized, &(&1 in @net_gen_headers))

    if plant_idx == nil or net_gen_idx == nil do
      Logger.warning("""
      EIA-923: required columns not found — NO capacity factors were ingested.
        Looking for a plant-id column (#{inspect(@plant_id_headers)}) and a \
      net-generation column (#{inspect(@net_gen_headers)}).
        Headers found: #{inspect(normalized)}
        Is the first CSV row the column-header row? (Title rows above the \
      headers must be removed when exporting the XLSX schedule.)
      """)

      {:error, :headers_not_found}
    else
      plant_net_gen = aggregate_net_generation(data, plant_idx, net_gen_idx)
      updated = write_capacity_factors(plant_net_gen)

      Logger.info(
        "EIA-923: capacity factors written for #{updated} of #{map_size(plant_net_gen)} plants"
      )

      {:ok, updated}
    end
  end

  def ingest_rows([]) do
    Logger.warning("EIA-923: generation file is empty — NO capacity factors were ingested.")
    {:error, :empty_file}
  end

  # Sum net generation over every row of each plant (a plant has one row per
  # prime-mover/fuel combination). Negative rows (e.g. pumped storage) are
  # kept in the sum; the final CF is clamped at write time.
  defp aggregate_net_generation(data, plant_idx, net_gen_idx) do
    Enum.reduce(data, %{}, fn cols, acc ->
      plant_id = cols |> Enum.at(plant_idx, "") |> normalize_plant_id()
      net_gen = parse_float(Enum.at(cols, net_gen_idx))

      if plant_id != "" and net_gen != nil do
        Map.update(acc, plant_id, net_gen, &(&1 + net_gen))
      else
        acc
      end
    end)
  end

  # One write per plant: CF = total net gen / (in-service capacity * 8760),
  # clamped to [0, 1]. Both the capacity denominator and the write target
  # only in-service generators — retired/standby units would dilute the
  # denominator and receive a meaningless CF.
  defp write_capacity_factors(plant_net_gen) do
    capacities =
      plant_net_gen
      |> Map.keys()
      |> Enum.chunk_every(5000)
      |> Enum.flat_map(fn chunk ->
        Repo.all(
          from g in Generator,
            where: g.eia_plant_id in ^chunk and g.status == "in_service" and g.p_max_mw > 0.0,
            group_by: g.eia_plant_id,
            select: {g.eia_plant_id, sum(g.p_max_mw)}
        )
      end)
      |> Map.new()

    Enum.reduce(plant_net_gen, 0, fn {plant_id, net_gen}, count ->
      case Map.get(capacities, plant_id) do
        capacity when is_number(capacity) and capacity > 0 ->
          cf = (net_gen / (capacity * @hours_in_year)) |> max(0.0) |> min(1.0)

          {n, _} =
            from(g in Generator,
              where: g.eia_plant_id == ^plant_id and g.status == "in_service"
            )
            |> Repo.update_all(set: [capacity_factor: cf])

          count + if(n > 0, do: 1, else: 0)

        _ ->
          count
      end
    end)
  end

  defp normalize_header(header) do
    header
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # eia_plant_id is stored as the integer string form ("613", not "613.0").
  defp normalize_plant_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace_suffix(".0", "")
  end

  defp find_file(path, patterns) do
    Enum.find_value(patterns, fn pattern ->
      case Path.wildcard(Path.join(path, pattern)) do
        [found | _] -> found
        [] -> nil
      end
    end)
  end

  defp parse_float(nil), do: nil
  defp parse_float(val) when is_number(val), do: val * 1.0

  defp parse_float(val) when is_binary(val) do
    # EIA-923 formats numbers with thousands separators ("1,234,567").
    cleaned = val |> String.trim() |> String.replace(",", "")

    case Float.parse(cleaned) do
      {f, _} -> f
      :error -> nil
    end
  end
end
