defmodule PowerModel.Ingestion.EPA.EGrid do
  @moduledoc """
  Ingest data from EPA eGRID dataset (XLSX format).

  Updates generators with capacity factors from the GEN sheet,
  and balancing authority / NERC region from the PLNT sheet.

  eGRID provides generator-level capacity factors for ~25k generators,
  which is critical for realistic dispatch modeling.
  """

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Grid.Generator

  def ingest(path) do
    xlsx_file = cond do
      File.regular?(path) and String.ends_with?(path, ".xlsx") ->
        path
      File.dir?(path) ->
        case Path.wildcard(Path.join(path, "egrid*.xlsx")) do
          [found | _] -> found
          [] -> nil
        end
      true -> nil
    end

    if xlsx_file do
      IO.puts("Reading eGRID from #{xlsx_file}...")
      ingest_generator_capacity_factors(xlsx_file)
    else
      IO.puts("No eGRID XLSX file found at #{path}")
    end
  end

  @doc """
  Ingest generator-level capacity factors from the GEN sheet.
  Matches on eia_plant_id (ORISPL) since we don't store generator sub-IDs.
  When multiple generators exist at a plant, each gets the eGRID CF for that
  specific generator if distinguishable, otherwise the plant average.
  """
  def ingest_generator_capacity_factors(xlsx_path) do
    gen_csv = extract_sheet_to_csv(xlsx_path, "GEN")

    if gen_csv do
      lines = String.split(gen_csv, "\n", trim: true)

      if length(lines) >= 2 do
        field_names = parse_csv_row(Enum.at(lines, 1))
        oris_idx = Enum.find_index(field_names, &(&1 == "ORISPL"))
        cfact_idx = Enum.find_index(field_names, &(&1 == "CFACT"))
        namepcap_idx = Enum.find_index(field_names, &(&1 == "NAMEPCAP"))
        _fuel_idx = Enum.find_index(field_names, &(&1 == "FUELG1"))

        if oris_idx && cfact_idx do
          plant_cfs =
            lines
            |> Enum.drop(2)
            |> Enum.map(&parse_csv_row/1)
            |> Enum.reduce(%{}, fn cols, acc ->
              plant_id = Enum.at(cols, oris_idx)
              cf = parse_float(Enum.at(cols, cfact_idx))
              cap = parse_float(Enum.at(cols, namepcap_idx)) || 0.0

              if plant_id && cf && cf > 0 do
                existing = Map.get(acc, plant_id, {0.0, 0.0})
                {weighted_sum, total_cap} = existing
                Map.put(acc, plant_id, {weighted_sum + cf * cap, total_cap + cap})
              else
                acc
              end
            end)
            |> Enum.map(fn {plant_id, {weighted_sum, total_cap}} ->
              avg_cf = if total_cap > 0, do: weighted_sum / total_cap, else: 0.0
              {plant_id, max(0.01, min(1.0, avg_cf))}
            end)
            |> Map.new()

          IO.puts("  eGRID plants with CF data: #{map_size(plant_cfs)}")

          updated =
            plant_cfs
            |> Enum.chunk_every(500)
            |> Enum.reduce(0, fn batch, total ->
              count = Enum.reduce(batch, 0, fn {plant_id, cf}, cnt ->
                {n, _} = from(g in Generator,
                  where: g.eia_plant_id == ^plant_id
                )
                |> Repo.update_all(set: [capacity_factor: cf])
                cnt + n
              end)
              total + count
            end)

          IO.puts("  Generators updated with capacity factors: #{updated}")
        else
          IO.puts("  Could not find ORISPL/CFACT columns in GEN sheet")
        end
      end
    end
  end

  defp extract_sheet_to_csv(xlsx_path, sheet_prefix) do
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

  defp parse_csv_row(line) do
    line
    |> String.trim()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn s -> String.trim(s, "\"") end)
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
