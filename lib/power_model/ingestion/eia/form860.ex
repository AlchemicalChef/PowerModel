defmodule PowerModel.Ingestion.EIA.Form860 do
  @moduledoc """
  Ingest generator data from EIA-860 Schedule 2/3 CSV files.

  ## File expectations

  EIA publishes the 860 workbook as XLSX; the sheets must be exported to CSV
  before ingestion:

    * `3_1_Generator_Y<year>.csv` — Schedule 3.1 generator list. Must include
      the `Plant Code`, `Generator ID`, `Nameplate Capacity (MW)`, and
      `Status` columns. `Summer Capacity (MW)` and `Winter Capacity (MW)` are
      read when present (see "Seasonal capability" below).
    * `2___Plant_Y<year>.csv` — Schedule 2 plant list, the ONLY source of
      plant coordinates (`Plant Code`, `Latitude`, `Longitude`).

  **The first row of each CSV must be the column-header row.** The published
  XLSX sheets carry a one-line title row above the headers — delete it when
  exporting, otherwise every header lookup misses. The Plant file is
  mandatory: without it every generator ingests without coordinates and is
  invisible to bus mapping and the map, so a missing Plant file raises.

  ## Identity and re-ingest

  A generator's natural key is `{eia_plant_id, generator_id}` (EIA Plant Code
  + EIA Generator ID). Inserts upsert on that key, so re-running the ingest
  updates units in place instead of duplicating the fleet. Rows without a
  `Generator ID` column (non-standard files) cannot be deduplicated and will
  duplicate on re-ingest.

  ## Seasonal capability

  `Summer Capacity (MW)` and `Winter Capacity (MW)` are the net capability a
  unit can actually deliver in each season; nameplate is a rating-plate number
  that overstates it (measured: 83.1 GW of phantom summer capability
  nationally, concentrated in the reserve-providing gas fleet). Both columns
  are ~99.7% populated in the 2024 Operable sheet and land in
  `summer_capacity_mw` / `winter_capacity_mw`.

  A blank or non-numeric cell stores NULL, never 0.0 — a zero would read as a
  unit with no capability at all, while NULL lets consumers fall back to
  `p_max_mw`. Nothing is ever clamped: a value flattened to nameplate would
  hide the fact that the two disagree.

  Values more than 5% above nameplate are counted per season and reported at
  the end of the ingest. Summer is additionally warned about per row, because
  the two seasons mean different things:

    * **Summer** (1,079 units / +12.9 GW on the 2024 file) has no benign
      explanation, so each offender is named for chasing upstream.
    * **Winter** (1,868 units / +22.2 GW) is usually genuine — combustion
      turbines gain output in cold, dense air. Naming ~1,900 units would bury
      the summer anomalies that matter, so only the total is reported.

  The end-of-ingest totals come from counters, not from the log: a burst of
  per-row warnings that size is silently truncated by the logger (measured:
  1,079 emitted, 114 printed), so the log alone undercounts by ~90%.

  ## Sector

  `Sector Name` separates grid-scale plant from generation sited at a host
  facility. It is stored raw in `sector`, and `utility_scale` carries the
  derived classification consumers read:

    * `Electric Utility`, `IPP Non-CHP`, `IPP CHP` -> `utility_scale = true`
    * `Commercial CHP`, `Commercial Non-CHP`, `Industrial CHP`,
      `Industrial Non-CHP` -> `utility_scale = false`
    * blank or unrecognized -> `true`, logged at debug. EIA-860 is
      overwhelmingly utility-metered plant (25.5k of 26.9k rows on the 2024
      file, versus 2 blanks), so utility-scale is the safe default; guessing
      "onsite" would pull the unit out of the fuel-anchored dispatch pool.

  The distinction matters because EIA-930's per-fuel solar and wind columns
  report utility-scale generation only — see `PowerModel.Dispatch`.

  ## Capacity-factor defaults

  A generator with a NULL `capacity_factor` would dispatch at 100% of
  nameplate (`capacity_factor || 1.0` at the solver call sites). After
  ingestion, `backfill_missing_capacity_factors/0` fills any remaining NULLs
  with fuel-typical defaults (see `@default_capacity_factors`) so no ingested
  unit ever reaches the solvers at nameplate by accident. Measured values
  (EIA-923 / eGRID) overwrite these defaults when those passes run.
  """

  NimbleCSV.define(EIA860Parser, separator: ",", escape: "\"")

  require Logger

  import Ecto.Query

  alias PowerModel.Repo
  alias PowerModel.Grid.Generator

  # Fuel-typical annual capacity factors (approximate recent EIA fleet
  # averages). Used ONLY where no measured CF (EIA-923 / eGRID) exists —
  # both by `backfill_missing_capacity_factors/0` and, mirrored in SQL, by
  # the BackfillGeneratorCapacityFactors migration. Keep the two in sync.
  @default_capacity_factors %{
    "nuclear" => 0.93,
    "coal" => 0.50,
    # combined cycle vs. simple-cycle peaker — split by prime mover
    "gas_cc" => 0.55,
    "gas_ct" => 0.12,
    "oil" => 0.10,
    "hydro" => 0.40,
    "wind" => 0.35,
    "solar" => 0.25,
    "storage" => 0.10,
    "geothermal" => 0.70,
    "other" => 0.40
  }

  # EIA energy-source codes -> default-CF category. Gas maps to "gas" here
  # and is split into gas_cc / gas_ct by prime mover in categorize_fuel/2.
  @fuel_categories %{
    "NUC" => "nuclear",
    "BIT" => "coal",
    "SUB" => "coal",
    "LIG" => "coal",
    "ANT" => "coal",
    "RC" => "coal",
    "WC" => "coal",
    "SGC" => "coal",
    "NG" => "gas",
    "BFG" => "gas",
    "OG" => "gas",
    "LFG" => "gas",
    "OBG" => "gas",
    "PG" => "gas",
    "DFO" => "oil",
    "RFO" => "oil",
    "KER" => "oil",
    "JF" => "oil",
    "WO" => "oil",
    "PC" => "oil",
    "WAT" => "hydro",
    "WND" => "wind",
    "SUN" => "solar",
    "MWH" => "storage",
    "GEO" => "geothermal"
  }

  # EIA prime movers that indicate a combined-cycle unit (CT here is the
  # combined-cycle combustion-turbine part, NOT a simple-cycle turbine —
  # simple cycle is GT/IC).
  @combined_cycle_prime_movers ~w(CC CA CT CS)

  # EIA-860 "Sector Name" values describing grid-scale plant. The other four
  # published values name a host facility ("Commercial CHP",
  # "Commercial Non-CHP", "Industrial CHP", "Industrial Non-CHP") and are
  # matched by prefix so a renamed CHP suffix still classifies correctly.
  @utility_scale_sectors ["ELECTRIC UTILITY", "IPP NON-CHP", "IPP CHP"]
  @onsite_sector_prefixes ~w(COMMERCIAL INDUSTRIAL)

  # How far a reported seasonal capability may sit above nameplate before the
  # row is flagged (see the "Seasonal capability" moduledoc section).
  @seasonal_tolerance 1.05

  # Slots in the seasonal-excess counter: each season occupies a unit count
  # followed by its accumulated whole MW above nameplate.
  @summer_units 1
  @winter_units 3

  @plant_file_patterns ~w(
    2___Plant_Y2024.csv
    2___Plant_Y2023.csv
    2___Plant_Y2022.csv
    Plant_Y*.csv
  )

  def ingest(path) do
    generators_path = find_file(path, ~w(
      3_1_Generator_Y2024.csv
      3_1_Generator_Y2023.csv
      3_1_Generator_Y2022.csv
      generators.csv
    ))

    plant_path = find_file(path, @plant_file_patterns)

    if generators_path do
      # The Plant file is the only source of coordinates; a coordinate-less
      # fleet is invisible to bus mapping, so refuse to ingest without it.
      if plant_path == nil do
        raise """
        EIA-860 Plant file not found in #{path}.

        Expected one of: #{Enum.join(@plant_file_patterns, ", ")}

        The Plant file (EIA-860 Schedule 2) is the only source of plant
        coordinates; without it every generator would ingest without
        coordinates and be invisible to bus mapping and the map. Export the
        "2___Plant" sheet of the EIA-860 XLSX workbook to CSV, deleting the
        leading title row so the first row is the column headers.
        """
      end

      plant_coords = build_plant_coords(plant_path)

      # Seasonal over-capability is tallied across Flow's parallel stages.
      # Counters, not log lines, are the authoritative count: a burst of
      # per-row warnings this large is silently truncated by the logger
      # (measured: 1,079 emitted, 114 printed).
      seasonal_excess = :counters.new(4, [:write_concurrency])

      generators_path
      |> File.stream!([:trim_bom])
      |> EIA860Parser.parse_stream(skip_headers: false)
      |> Stream.transform(nil, fn
        # First row is headers
        row, nil -> {[], row}
        row, headers -> {[Enum.zip(headers, row) |> Map.new()], headers}
      end)
      |> Flow.from_enumerable(max_demand: 200)
      |> Flow.map(&parse_generator(&1, plant_coords, seasonal_excess))
      |> Flow.filter(&(&1 != nil))
      |> Flow.map(&insert_generator/1)
      |> Flow.run()

      report_seasonal_excess(seasonal_excess)
      backfill_missing_capacity_factors()

      :ok
    else
      {:error, "No EIA-860 generator file found at #{path}"}
    end
  end

  defp build_plant_coords(plant_path) do
    plant_path
    |> File.stream!([:trim_bom])
    |> EIA860Parser.parse_stream(skip_headers: false)
    |> Stream.transform(nil, fn
      row, nil -> {[], row}
      row, headers -> {[Enum.zip(headers, row) |> Map.new()], headers}
    end)
    |> Enum.reduce(%{}, fn row, acc ->
      plant_code = Map.get(row, "Plant Code")
      lat = parse_float(Map.get(row, "Latitude"))
      lon = parse_float(Map.get(row, "Longitude"))

      if plant_code && lat && lon do
        Map.put(acc, to_string(plant_code), {lon, lat})
      else
        acc
      end
    end)
  end

  defp parse_generator(row, plant_coords, seasonal_excess) do
    try do
      plant_id = Map.get(row, "Plant Code") || Map.get(row, "Plant ID")

      nameplate =
        parse_float(
          Map.get(row, "Nameplate Capacity (MW)") ||
            Map.get(row, "Capacity (MW)")
        )

      if plant_id && nameplate && nameplate > 0 do
        generator_id = parse_generator_id(Map.get(row, "Generator ID"))
        sector = parse_sector(Map.get(row, "Sector Name"))

        # Try coordinates from row first, then from plant lookup
        lat = parse_float(Map.get(row, "Latitude"))
        lon = parse_float(Map.get(row, "Longitude"))

        {lon, lat} =
          case {lon, lat} do
            {nil, _} -> Map.get(plant_coords, to_string(plant_id), {nil, nil})
            {_, nil} -> Map.get(plant_coords, to_string(plant_id), {nil, nil})
            pair -> pair
          end

        coords =
          if lat && lon do
            %Geo.Point{coordinates: {lon, lat}, srid: 4326}
          end

        %{
          eia_plant_id: to_string(plant_id),
          generator_id: generator_id,
          fuel_type: Map.get(row, "Energy Source 1") || Map.get(row, "Fuel Type"),
          prime_mover: Map.get(row, "Prime Mover") || Map.get(row, "Technology"),
          p_max_mw: nameplate,
          p_min_mw: parse_float(Map.get(row, "Minimum Load (MW)")) || 0.0,
          summer_capacity_mw:
            summer_capacity(row, nameplate, plant_id, generator_id, seasonal_excess),
          winter_capacity_mw: winter_capacity(row, nameplate, seasonal_excess),
          coordinates: coords,
          status: parse_status(Map.get(row, "Status") || Map.get(row, "Operating Status")),
          sector: sector,
          utility_scale: utility_scale?(sector),
          # Set by BusMapper
          bus_id: nil
        }
      end
    rescue
      _ -> nil
    end
  end

  # Summer capability above nameplate has no benign physical explanation, so
  # each offending row is named: these are the ones worth chasing upstream.
  defp summer_capacity(row, nameplate, plant_id, generator_id, seasonal_excess) do
    mw = parse_seasonal(row, "Summer Capacity (MW)")

    if mw && mw > nameplate * @seasonal_tolerance do
      tally(seasonal_excess, @summer_units, mw - nameplate)

      Logger.warning(
        "EIA-860: Summer Capacity (MW) #{mw} exceeds nameplate #{nameplate} MW by >5% " <>
          "for plant #{plant_id} unit #{generator_id || "?"}; storing as reported"
      )
    end

    mw
  end

  # Winter capability above nameplate is usually real — combustion turbines
  # gain output in cold, dense air — so the rows are tallied and reported once
  # rather than warned about individually (a per-row warning fires ~1,900
  # times on the national file and buries the summer anomalies).
  defp winter_capacity(row, nameplate, seasonal_excess) do
    mw = parse_seasonal(row, "Winter Capacity (MW)")

    if mw && mw > nameplate * @seasonal_tolerance do
      tally(seasonal_excess, @winter_units, mw - nameplate)
    end

    mw
  end

  defp tally(seasonal_excess, units_slot, excess_mw) do
    :counters.add(seasonal_excess, units_slot, 1)
    :counters.add(seasonal_excess, units_slot + 1, round(excess_mw))
  end

  # Seasonal net capability, stored as reported. A blank cell yields nil (NOT
  # 0.0 — a zero would read as a unit with no capability, while nil lets
  # consumers fall back to nameplate). Nothing is clamped: flattening a
  # reported value to nameplate would destroy the evidence that the two
  # disagree.
  defp parse_seasonal(row, column), do: parse_float(Map.get(row, column))

  # The authoritative counts. Each summer offender is also named in its own
  # warning above, but the logger drops most of a burst that size, so the
  # totals are reported here where nothing can discard them.
  defp report_seasonal_excess(seasonal_excess) do
    summer = :counters.get(seasonal_excess, @summer_units)
    winter = :counters.get(seasonal_excess, @winter_units)

    if summer > 0 do
      warn_excess(
        "summer",
        summer,
        :counters.get(seasonal_excess, @summer_units + 1),
        "each named in a warning above, unless the logger truncated the burst"
      )
    end

    if winter > 0 do
      warn_excess(
        "winter",
        winter,
        :counters.get(seasonal_excess, @winter_units + 1),
        "expected for combustion turbines in cold, dense air"
      )
    end

    {summer, winter}
  end

  defp warn_excess(season, units, excess_mw, note) do
    generators = if units == 1, do: "1 generator", else: "#{units} generators"

    msg =
      "EIA-860: #{season} capability above nameplate on #{generators} " <>
        "(+#{excess_mw} MW total, stored as reported) — #{note}"

    IO.puts("  " <> msg)
    Logger.warning(msg)
  end

  @doc """
  The EIA-860 `Sector Name` cell, trimmed, or `nil` when blank.

  Stored raw rather than as a code so the seven published values survive the
  ingest and can be re-derived if the `utility_scale` rule ever changes.
  """
  def parse_sector(nil), do: nil

  def parse_sector(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      name -> name
    end
  end

  @doc """
  Whether an EIA-860 sector describes grid-scale, utility-metered plant.

  `Electric Utility` and both IPP sectors are grid-scale; `Commercial *` and
  `Industrial *` sit at a host facility and are metered behind it, so EIA-930
  does not count them in its per-fuel generation columns.

  A blank or unrecognized sector returns `true` and logs at debug: EIA-860 is
  overwhelmingly utility-metered (2 blank rows on the 2024 national file), and
  defaulting to onsite would silently pull those units out of the
  fuel-anchored dispatch pool.
  """
  def utility_scale?(sector) do
    normalized = sector |> to_string() |> String.trim() |> String.upcase()

    cond do
      normalized in @utility_scale_sectors ->
        true

      String.starts_with?(normalized, @onsite_sector_prefixes) ->
        false

      true ->
        Logger.debug(
          "EIA-860: blank or unrecognized Sector Name #{inspect(sector)}; " <>
            "treating as utility-scale"
        )

        true
    end
  end

  defp parse_generator_id(nil), do: nil

  defp parse_generator_id(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      id -> id
    end
  end

  defp insert_generator(nil), do: :ok

  defp insert_generator(attrs) do
    # Upsert on the natural key {eia_plant_id, generator_id} so re-ingest
    # updates units in place instead of duplicating the fleet. bus_id and
    # capacity_factor are deliberately NOT replaced: they are enriched by
    # later pipeline stages (BusMapper, EIA-923, eGRID) and must survive a
    # re-ingest. The fragment mirrors the partial unique index
    # generators_eia_plant_id_generator_id_index.
    %Generator{}
    |> Generator.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :fuel_type,
           :prime_mover,
           :p_max_mw,
           :p_min_mw,
           :summer_capacity_mw,
           :winter_capacity_mw,
           :sector,
           :utility_scale,
           :status,
           :coordinates,
           :updated_at
         ]},
      conflict_target:
        {:unsafe_fragment,
         "(eia_plant_id, generator_id) WHERE eia_plant_id IS NOT NULL AND generator_id IS NOT NULL"}
    )
  end

  @doc """
  Fill NULL `capacity_factor` rows with fuel-typical defaults.

  A NULL CF dispatches the unit at 100% of nameplate (`|| 1.0` at the solver
  call sites), so every ingest ends with this pass. Measured CFs written by
  the EIA-923 / eGRID passes are never touched — only NULLs are filled.

  Logs the generator count and MW backfilled per fuel category. Returns the
  total number of rows updated.
  """
  def backfill_missing_capacity_factors do
    rows =
      Repo.all(
        from g in Generator,
          where: is_nil(g.capacity_factor),
          select: {g.id, g.fuel_type, g.prime_mover, g.p_max_mw}
      )

    rows
    |> Enum.group_by(fn {_id, fuel, pm, _mw} -> categorize_fuel(fuel, pm) end)
    |> Enum.map(fn {category, group} ->
      cf = Map.fetch!(@default_capacity_factors, category)
      ids = Enum.map(group, fn {id, _, _, _} -> id end)
      mw = group |> Enum.map(fn {_, _, _, mw} -> mw || 0.0 end) |> Enum.sum()

      n =
        ids
        |> Enum.chunk_every(5000)
        |> Enum.reduce(0, fn chunk, acc ->
          {count, _} =
            from(g in Generator, where: g.id in ^chunk)
            |> Repo.update_all(set: [capacity_factor: cf])

          acc + count
        end)

      msg =
        "EIA-860: backfilled default capacity_factor #{cf} (#{category}) " <>
          "on #{n} generators / #{Float.round(mw * 1.0, 1)} MW without measured CF"

      IO.puts("  " <> msg)
      Logger.info(msg)

      n
    end)
    |> Enum.sum()
  end

  @doc """
  Default-CF category for a fuel-type / prime-mover pair. Gas splits into
  combined cycle (`gas_cc`: prime movers CC/CA/CT/CS) vs. simple-cycle
  peakers (`gas_ct`: GT/IC/ST and unknown). Unrecognized fuels are `"other"`.
  """
  def categorize_fuel(fuel_type, prime_mover) do
    code = fuel_type |> to_string() |> String.trim() |> String.upcase()
    pm = prime_mover |> to_string() |> String.trim() |> String.upcase()

    case Map.get(@fuel_categories, code) do
      "gas" -> if pm in @combined_cycle_prime_movers, do: "gas_cc", else: "gas_ct"
      nil -> "other"
      category -> category
    end
  end

  @doc """
  The fuel-typical default capacity factor for a fuel-type / prime-mover pair.
  """
  def default_capacity_factor(fuel_type, prime_mover) do
    Map.fetch!(@default_capacity_factors, categorize_fuel(fuel_type, prime_mover))
  end

  defp find_file(path, patterns) do
    Enum.find_value(patterns, fn pattern ->
      full = Path.join(path, pattern)

      case Path.wildcard(full) do
        [found | _] -> found
        [] -> nil
      end
    end)
  end

  defp parse_float(nil), do: nil
  defp parse_float(val) when is_number(val), do: val * 1.0

  defp parse_float(val) when is_binary(val) do
    cleaned = String.trim(val)

    case Float.parse(cleaned) do
      {f, _} -> f
      :error -> nil
    end
  end

  @doc """
  Maps an EIA-860 Schedule 3 generator status code to an internal status string.

  Only generators whose status is `"in_service"` are counted by the network
  builder and the load estimator (85% of in-service nameplate seeds the synthetic
  load baseline — see `PowerModel.Ingestion.LoadEstimator`). Any code that is not
  currently generating must therefore map to a non-`"in_service"` status, or it
  inflates that baseline.

  EIA-860 status codes:
    * `OP` operating                          -> `"in_service"`
    * `SB` standby / backup (available)       -> `"standby"`  (not counted, kept distinct)
    * `OA` out of service, but expected       -> `"standby"`  (exists and will return;
      to return this/next calendar year          not currently generating)
    * `OS` out of service (exists, offline)   -> `"out_of_service"`
    * `RE` retired (permanently removed)      -> `"retired"`
    * `TS`/`T`/`U`/`V`/`L`/`P`/`OT` planned,  -> `"out_of_service"`
      proposed, under construction, other
    * `CN` cancelled                          -> `"out_of_service"`

  A missing status (absent column or blank cell) defaults to `"in_service"`, since
  the Schedule 3.1 file lists existing units. Any other, non-blank code is treated
  as `"out_of_service"` and logged, rather than silently counted as operating.
  """
  def parse_status(nil), do: "in_service"

  def parse_status(status) when is_binary(status) do
    case status |> String.trim() |> String.upcase() do
      "" ->
        "in_service"

      code when code in ~w(OP OPERATING) ->
        "in_service"

      # OA: out of service but expected to return to service — the unit
      # exists and is dispatchable in the near term, but is not currently
      # generating. Same treatment as standby: kept, not counted toward the
      # in-service baseline.
      code when code in ~w(SB STANDBY OA) ->
        "standby"

      "OS" ->
        "out_of_service"

      code when code in ~w(RE RETIRED) ->
        "retired"

      code when code in ~w(TS T U V L P OT CN) ->
        "out_of_service"

      code ->
        Logger.warning(
          "EIA-860: unrecognized generator status #{inspect(code)}; treating as out_of_service"
        )

        "out_of_service"
    end
  end
end
