defmodule PowerModel.Ingestion.EPA.EGrid do
  @moduledoc """
  Ingest data from EPA eGRID dataset (XLSX format).

  Updates generators with capacity factors from the GEN sheet,
  and balancing authority / NERC region from the PLNT sheet.

  eGRID provides generator-level capacity factors for ~25k generators,
  which is critical for realistic dispatch modeling.

  The extracted sheets are parsed with NimbleCSV (RFC-4180), so plant names
  containing commas ("General James M. Gavin, LLC") survive intact. Unit
  CFACT values are clamped to [0, 1] BEFORE capacity-weighting (eGRID data
  contains values up to ~3.4 and negatives); plants whose units all report
  non-positive CFs store a true 0.0 rather than being skipped or floored.
  """

  NimbleCSV.define(EGridGENParser, separator: ",", escape: "\"")

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Grid.Generator
  alias PowerModel.Ingestion.EIA.Form860

  def ingest(path) do
    xlsx_file =
      cond do
        File.regular?(path) and String.ends_with?(path, ".xlsx") ->
          path

        File.dir?(path) ->
          case Path.wildcard(Path.join(path, "egrid*.xlsx")) do
            [found | _] -> found
            [] -> nil
          end

        true ->
          nil
      end

    if xlsx_file do
      IO.puts("Reading eGRID from #{xlsx_file}...")
      result = ingest_generator_capacity_factors(xlsx_file)

      # eGRID is the last capacity-factor source in the pipeline: fill any
      # generator still lacking a measured CF with its fuel-typical default
      # so nothing dispatches at 100% of nameplate by accident.
      Form860.backfill_missing_capacity_factors()

      result
    else
      IO.puts("No eGRID XLSX file found at #{path}")
      {:error, :no_egrid_file}
    end
  end

  @doc """
  Ingest generator-level capacity factors from the GEN sheet.
  Matches on eia_plant_id (ORISPL) since we don't store eGRID unit sub-IDs;
  each plant stores the capacity-weighted average CF of its units.
  """
  def ingest_generator_capacity_factors(xlsx_path) do
    # Convert XLSX to CSV via Python, then parse
    gen_csv = extract_sheet_to_csv(xlsx_path, "GEN")

    if gen_csv do
      case parse_gen_sheet(gen_csv) do
        {:ok, plant_cfs} ->
          IO.puts("  eGRID plants with CF data: #{map_size(plant_cfs)}")
          updated = apply_plant_capacity_factors(plant_cfs)
          IO.puts("  Generators updated with capacity factors: #{updated}")
          {:ok, updated}

        {:error, reason} = error ->
          IO.puts("  eGRID GEN sheet not ingested: #{inspect(reason)}")
          error
      end
    else
      IO.puts("  Could not extract GEN sheet from #{xlsx_path}")
      {:error, :sheet_extraction_failed}
    end
  end

  @doc """
  Parse the GEN sheet CSV text (row 1 human-readable descriptions, row 2
  field names, data from row 3) into `{:ok, %{orispl => capacity_factor}}`.

  Each unit's CFACT is clamped to [0, 1] before capacity-weighting. Units
  with a CFACT cell are counted even when non-positive, so an idle plant
  yields 0.0 (not NULL, not a 0.01 floor); units without a CFACT are skipped.
  """
  def parse_gen_sheet(csv) when is_binary(csv) do
    case EGridGENParser.parse_string(csv, skip_headers: false) do
      [_descriptions, field_names | data] ->
        oris_idx = Enum.find_index(field_names, &(&1 == "ORISPL"))
        cfact_idx = Enum.find_index(field_names, &(&1 == "CFACT"))
        namepcap_idx = Enum.find_index(field_names, &(&1 == "NAMEPCAP"))

        if oris_idx && cfact_idx do
          {:ok, aggregate_plant_cfs(data, oris_idx, cfact_idx, namepcap_idx)}
        else
          {:error, {:columns_not_found, field_names}}
        end

      _ ->
        {:error, :gen_sheet_too_short}
    end
  end

  defp aggregate_plant_cfs(data, oris_idx, cfact_idx, namepcap_idx) do
    data
    |> Enum.reduce(%{}, fn cols, acc ->
      plant_id = cols |> Enum.at(oris_idx, "") |> normalize_plant_id()
      cf = parse_float(Enum.at(cols, cfact_idx))
      cap = (namepcap_idx && parse_float(Enum.at(cols, namepcap_idx))) || 0.0

      if plant_id != "" and cf != nil do
        # Clamp per unit BEFORE weighting: eGRID CFACT contains values up to
        # ~3.4 and negatives. A true-zero unit still participates so
        # all-idle plants resolve to 0.0 instead of staying NULL.
        clamped = cf |> max(0.0) |> min(1.0)

        Map.update(acc, plant_id, {clamped * cap, cap, clamped, 1}, fn
          {weighted, total_cap, cf_sum, n} ->
            {weighted + clamped * cap, total_cap + cap, cf_sum + clamped, n + 1}
        end)
      else
        acc
      end
    end)
    |> Map.new(fn {plant_id, {weighted, total_cap, cf_sum, n}} ->
      # Capacity-weighted average; simple mean when no unit reported capacity.
      avg = if total_cap > 0, do: weighted / total_cap, else: cf_sum / n
      {plant_id, avg |> max(0.0) |> min(1.0)}
    end)
  end

  @doc """
  Write plant-level capacity factors (`%{orispl => cf}`) to the generators
  table. Returns the number of generator rows updated.
  """
  def apply_plant_capacity_factors(plant_cfs) do
    plant_cfs
    |> Enum.chunk_every(500)
    |> Enum.reduce(0, fn batch, total ->
      count =
        Enum.reduce(batch, 0, fn {plant_id, cf}, cnt ->
          {n, _} =
            from(g in Generator,
              where: g.eia_plant_id == ^plant_id
            )
            |> Repo.update_all(set: [capacity_factor: cf])

          cnt + n
        end)

      total + count
    end)
  end

  @doc """
  Extract a sheet from an XLSX file to CSV text using Python/openpyxl.
  Matches the first sheet whose name starts with `sheet_prefix` (e.g. "GEN",
  "PLNT"). Returns the CSV string, or nil on failure.
  """
  def extract_sheet_to_csv(xlsx_path, sheet_prefix) do
    script = """
    import openpyxl, csv, io, sys
    wb = openpyxl.load_workbook('#{xlsx_path}', read_only=True, data_only=True)
    sheet = None
    for name in wb.sheetnames:
        if name.startswith('#{sheet_prefix}'):
            sheet = wb[name]
            break
    if not sheet:
        sys.exit(1)
    out = io.StringIO()
    writer = csv.writer(out)
    for row in sheet.iter_rows(values_only=True):
        writer.writerow([str(c) if c is not None else '' for c in row])
    print(out.getvalue())
    wb.close()
    """

    case System.cmd("python3", ["-c", script], stderr_to_stdout: true) do
      {output, 0} -> output
      _ -> nil
    end
  end

  # openpyxl renders integer cells as "613" but float cells as "613.0";
  # eia_plant_id is stored as the integer string form.
  defp normalize_plant_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace_suffix(".0", "")
  end

  defp parse_float(nil), do: nil
  defp parse_float(""), do: nil
  defp parse_float(val) when is_number(val), do: val * 1.0

  defp parse_float(val) when is_binary(val) do
    case Float.parse(String.trim(val)) do
      {f, _} -> f
      :error -> nil
    end
  end
end
