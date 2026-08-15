defmodule PowerModel.Ingestion.EPA.EGrid do
  @moduledoc """
  Ingest data from EPA eGRID dataset (XLSX format).

  Updates generators with capacity factors from the GEN sheet,
  and balancing authority / NERC region from the PLNT sheet.

  eGRID provides generator-level capacity factors for ~25k generators,
  which is critical for realistic dispatch modeling.

  ## Per-unit capacity factors

  The GEN sheet is keyed by `{ORISPL, GENID}` — plant code plus EIA generator
  ID — which is exactly the natural key generators now carry, so unit CFs are
  stored per unit rather than collapsed to a plant average. This matters:
  31.4% of multi-unit plants in eGRID2022 report units with divergent CFs, and
  a plant average dispatches a base-loaded unit and its idle twin identically.

  Two passes run, in order:

    1. every generator of a plant present in the GEN sheet gets the
       capacity-weighted plant average, then
    2. every generator whose `{eia_plant_id, generator_id}` matches a GEN row
       is overwritten with its own unit CF.

  So a unit that joins gets its measured CF and a unit that does not (no
  `generator_id`, an ID that changed between vintages, a unit newer than the
  eGRID vintage) still falls back to the plant average instead of NULL. Both
  passes are idempotent — re-ingest recomputes the same values in place.
  Measured against the live data files (eGRID2022 GEN sheet vs. the EIA-860
  2024 Operable sheet), the per-unit join covers 89.5% of units and 91.4% of
  nameplate MW.

  The extracted sheets are parsed with NimbleCSV (RFC-4180), so plant names
  containing commas ("General James M. Gavin, LLC") survive intact. Unit
  CFACT values are clamped to [0, 1] BEFORE being stored or capacity-weighted
  (eGRID data contains values up to ~3.4 and negatives); plants whose units
  all report non-positive CFs store a true 0.0 rather than being skipped or
  floored.
  """

  NimbleCSV.define(EGridGENParser, separator: ",", escape: "\"")

  alias PowerModel.Repo
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
  Ingest capacity factors from the GEN sheet, per unit where the
  `{ORISPL, GENID}` join hits and per plant everywhere else.

  Prints the join hit-rate in both units and MW so a vintage mismatch between
  eGRID and EIA-860 shows up as a number rather than as quietly averaged
  dispatch. Returns `{:ok, generators_updated}`.
  """
  def ingest_generator_capacity_factors(xlsx_path) do
    # Convert XLSX to CSV via Python, then parse
    gen_csv = extract_sheet_to_csv(xlsx_path, "GEN")

    if gen_csv do
      case parse_gen_sheet(gen_csv) do
        {:ok, cfs} ->
          IO.puts("  eGRID plants with CF data: #{map_size(cfs.plants)}")
          IO.puts("  eGRID units with CF data:  #{map_size(cfs.units)}")

          report = apply_capacity_factors(cfs)
          {:ok, report.updated}

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
  field names, data from row 3) into

      {:ok, %{plants: %{orispl => cf}, units: %{{orispl, genid} => cf}}}

  Each unit's CFACT is clamped to [0, 1] before it is stored or
  capacity-weighted. Units with a CFACT cell are counted even when
  non-positive, so an idle plant yields 0.0 (not NULL, not a 0.01 floor);
  units without a CFACT are skipped. A row with no GENID contributes to its
  plant average but produces no unit entry.
  """
  def parse_gen_sheet(csv) when is_binary(csv) do
    case EGridGENParser.parse_string(csv, skip_headers: false) do
      [_descriptions, field_names | data] ->
        oris_idx = Enum.find_index(field_names, &(&1 == "ORISPL"))
        cfact_idx = Enum.find_index(field_names, &(&1 == "CFACT"))
        namepcap_idx = Enum.find_index(field_names, &(&1 == "NAMEPCAP"))
        genid_idx = Enum.find_index(field_names, &(&1 == "GENID"))

        if oris_idx && cfact_idx do
          {:ok, aggregate_cfs(data, oris_idx, genid_idx, cfact_idx, namepcap_idx)}
        else
          {:error, {:columns_not_found, field_names}}
        end

      _ ->
        {:error, :gen_sheet_too_short}
    end
  end

  defp aggregate_cfs(data, oris_idx, genid_idx, cfact_idx, namepcap_idx) do
    {plants, units} =
      Enum.reduce(data, {%{}, %{}}, fn cols, {plants, units} = acc ->
        plant_id = cols |> Enum.at(oris_idx, "") |> normalize_id()
        gen_id = if genid_idx, do: cols |> Enum.at(genid_idx, "") |> normalize_id(), else: ""
        cf = parse_float(Enum.at(cols, cfact_idx))
        cap = (namepcap_idx && parse_float(Enum.at(cols, namepcap_idx))) || 0.0

        if plant_id != "" and cf != nil do
          # Clamp per unit BEFORE weighting: eGRID CFACT contains values up to
          # ~3.4 and negatives. A true-zero unit still participates so
          # all-idle plants resolve to 0.0 instead of staying NULL.
          clamped = cf |> max(0.0) |> min(1.0)

          # Unit entries accumulate the same way as plants so a duplicated
          # {ORISPL, GENID} pair weighs in rather than the last row winning.
          {accumulate(plants, plant_id, clamped, cap),
           if(gen_id == "",
             do: units,
             else: accumulate(units, {plant_id, gen_id}, clamped, cap)
           )}
        else
          acc
        end
      end)

    %{plants: finalize_cfs(plants), units: finalize_cfs(units)}
  end

  defp accumulate(acc, key, cf, cap) do
    Map.update(acc, key, {cf * cap, cap, cf, 1}, fn {weighted, total_cap, cf_sum, n} ->
      {weighted + cf * cap, total_cap + cap, cf_sum + cf, n + 1}
    end)
  end

  defp finalize_cfs(acc) do
    Map.new(acc, fn {key, {weighted, total_cap, cf_sum, n}} ->
      # Capacity-weighted average; simple mean when no unit reported capacity.
      avg = if total_cap > 0, do: weighted / total_cap, else: cf_sum / n
      {key, avg |> max(0.0) |> min(1.0)}
    end)
  end

  @doc """
  Write parsed capacity factors to the generators table: plant averages
  first, then per-unit values over the top wherever
  `{eia_plant_id, generator_id}` matches a GEN row.

  Returns a report with the rows and MW reached by each pass. `updated` is
  the number of distinct generator rows given a CF: every unit key parsed
  from the GEN sheet also feeds its plant's average, so for
  `parse_gen_sheet/1` output the plant pass reaches every row the unit pass
  does and the two `fallback_*` figures are the difference.
  """
  def apply_capacity_factors(%{plants: plant_cfs, units: unit_cfs}) do
    {plant_rows, plant_mw} = update_plant_cfs(plant_cfs)
    {unit_rows, unit_mw} = update_unit_cfs(unit_cfs)

    report = %{
      updated: plant_rows,
      unit_rows: unit_rows,
      unit_mw: unit_mw,
      fallback_rows: plant_rows - unit_rows,
      fallback_mw: plant_mw - unit_mw
    }

    IO.puts("  Generators updated with capacity factors: #{plant_rows}")

    IO.puts(
      "    per-unit CFACT join: #{unit_rows} of #{plant_rows} eGRID-covered units " <>
        "(#{pct(unit_rows, plant_rows)}) / #{mw(unit_mw)} of #{mw(plant_mw)} MW " <>
        "(#{pct(unit_mw, plant_mw)})"
    )

    IO.puts(
      "    plant-average fallback: #{report.fallback_rows} units / " <>
        "#{mw(report.fallback_mw)} MW"
    )

    report
  end

  @doc """
  Write plant-level capacity factors (`%{orispl => cf}`) to the generators
  table. Returns the number of generator rows updated.
  """
  def apply_plant_capacity_factors(plant_cfs) do
    {rows, _mw} = update_plant_cfs(plant_cfs)
    rows
  end

  @doc """
  Write per-unit capacity factors (`%{{orispl, genid} => cf}`) to the
  generators table, matching on the `{eia_plant_id, generator_id}` natural
  key. Returns the number of generator rows updated.
  """
  def apply_unit_capacity_factors(unit_cfs) do
    {rows, _mw} = update_unit_cfs(unit_cfs)
    rows
  end

  # One UPDATE ... FROM (unnest) per chunk rather than one per plant: the real
  # sheet carries ~11.7k plants / ~25k units, and a statement apiece dominated
  # the ingest. RETURNING carries the MW back for the hit-rate report.
  defp update_plant_cfs(plant_cfs) do
    plant_cfs
    |> Enum.chunk_every(2000)
    |> Enum.reduce({0, 0.0}, fn batch, acc ->
      {plant_ids, cfs} = Enum.unzip(batch)

      """
      UPDATE generators g
      SET capacity_factor = v.cf
      FROM (SELECT unnest($1::text[]) AS plant_id, unnest($2::float8[]) AS cf) v
      WHERE g.eia_plant_id = v.plant_id
      RETURNING COALESCE(g.p_max_mw, 0.0)
      """
      |> Repo.query!([plant_ids, cfs])
      |> tally(acc)
    end)
  end

  defp update_unit_cfs(unit_cfs) do
    unit_cfs
    |> Enum.chunk_every(2000)
    |> Enum.reduce({0, 0.0}, fn batch, acc ->
      plant_ids = Enum.map(batch, fn {{plant_id, _}, _} -> plant_id end)
      gen_ids = Enum.map(batch, fn {{_, gen_id}, _} -> gen_id end)
      cfs = Enum.map(batch, fn {_, cf} -> cf end)

      """
      UPDATE generators g
      SET capacity_factor = v.cf
      FROM (
        SELECT unnest($1::text[]) AS plant_id,
               unnest($2::text[]) AS gen_id,
               unnest($3::float8[]) AS cf
      ) v
      WHERE g.eia_plant_id = v.plant_id AND g.generator_id = v.gen_id
      RETURNING COALESCE(g.p_max_mw, 0.0)
      """
      |> Repo.query!([plant_ids, gen_ids, cfs])
      |> tally(acc)
    end)
  end

  defp tally(%Postgrex.Result{num_rows: n, rows: rows}, {total_rows, total_mw}) do
    {total_rows + n, total_mw + Enum.reduce(rows, 0.0, fn [mw], sum -> sum + mw end)}
  end

  defp pct(_part, whole) when whole == 0, do: "n/a"
  defp pct(part, whole), do: "#{Float.round(part / whole * 100, 1)}%"

  # Interpolating a float renders round MW totals in scientific notation
  # ("1.0e3"); fixed-point keeps the report readable.
  defp mw(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

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
  # eia_plant_id and generator_id are stored in the integer string form.
  # Generator IDs like "5.1" are left alone — only a trailing ".0" is a
  # float-rendering artifact.
  defp normalize_id(value) do
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
