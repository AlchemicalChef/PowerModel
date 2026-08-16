defmodule Mix.Tasks.PowerModel.Ingest do
  @moduledoc """
  Ingest grid data from public datasets.

  ## Usage

      mix power_model.ingest substations              # vendored snapshot (preferred)
      mix power_model.ingest substations /path/to/hifld/
      mix power_model.ingest substations --api
      mix power_model.ingest transmission_lines       # vendored snapshot (preferred)
      mix power_model.ingest transmission_lines /path/to/hifld/
      mix power_model.ingest transmission_lines --api
      mix power_model.ingest prepare_eia860           # xlsx zip -> the CSVs generators reads
      mix power_model.ingest generators /path/to/eia860/
      mix power_model.ingest capacity_factors /path/to/eia923/
      mix power_model.ingest egrid /path/to/egrid/
      mix power_model.ingest map_buses
      mix power_model.ingest connectivity_repair      # ROADMAP item 12 post-mapping pass
      mix power_model.ingest estimate_parameters
      mix power_model.ingest estimate_loads
      mix power_model.ingest map_bas [/path/to/egrid/]   # balancing authorities + bus assignment
      mix power_model.ingest demand [/path/to/eia930/]   # EIA-930 hourly demand profiles
      mix power_model.ingest population [/path/to/census/]  # county population (load weights)
      mix power_model.ingest btm_solar [/path/to/eia861/]   # EIA-861 rooftop PV on buses
      mix power_model.ingest validate [--update-baseline] # ingest-time validation gates
      mix power_model.ingest full_pipeline    # runs EVERY documented step in order

  ## Network sources (ROADMAP Phase 2 / REVIEW DAT-19)

  `substations` and `transmission_lines` default to the PINNED VENDORED
  SNAPSHOTS in `data/vendored/` (checksums and fetch URLs in
  `data/vendored/PROVENANCE.md`):

    * `hifld_substations_mirror_2021vintage.geojson` — 77,946 real yards with
      NAME/MAX_VOLT/MIN_VOLT. This is what lets line endpoints be keyed by
      substation NAME instead of snapped to whatever bus was nearby.
    * `hifld_next_transmission_lines_v1.geojsonl` — 94,619 lines, produced
      from the pinned GeoParquet by
      `python3 scripts/convert_vendored_hifld.py` (needs pyarrow).

  `--api` still works and is the documented fallback, but it pulls an
  unofficial 52,244-feature ArcGIS mirror — roughly half the network, from an
  org that is not HIFLD; HIFLD Open was shut down by DHS on 2025-08-26 and
  nothing authoritative is served live any more.

  Demand data pipeline (after the grid is built): `egrid` -> `map_bas` ->
  `demand` -> `population` -> `estimate_loads` -> `btm_solar`. Download
  EIA930_BALANCE_*.csv bulk files from
  https://www.eia.gov/electricity/gridmonitor, plus co-est*-alldata.csv
  (Census PEP county totals), *_Gaz_counties_national.txt (Census Gazetteer),
  and f861*.zip (https://www.eia.gov/electricity/data/eia861/zip/f8612024.zip)
  into data/ first.

  `btm_solar` (ROADMAP 2.5 item 30) needs county population, mapped BAs, and
  the estimated loads that define its bus universe, so it runs after all three.
  It is idempotent — the table is rebuilt from scratch on every run.

  `prepare_eia860` runs `scripts/prepare_eia860.py`, which extracts the two
  sheets `generators` needs out of `data/eia860_<year>.zip` (EIA ships XLSX
  only). `full_pipeline` runs it automatically when the CSVs are absent.

  `full_pipeline` (DAT-16/PLT-11) runs the complete documented order —
  network from the HIFLD API, then the file-based steps (generators,
  capacity factors, eGRID, EIA-930, Census; all read from `data/`),
  then water/datacenter mapping and cleanup. It prints each stage's
  result. File-based stages raise when their `data/` inputs are missing:
  a network-only "pipeline" that silently skips the fleet and demand data
  produces a degenerate 1 MW/bus grid while reporting success.

  The last pipeline stage is `validate` (ROADMAP Phase 0 item 3,
  `PowerModel.Ingestion.Validation`): EIA-930 hour completeness, eGRID vs
  EIA-860 vintage, and a topology census diffed against
  `priv/topology_baseline.json`. It prints a summary table; warnings are loud
  but let the pipeline finish, while a topology regression fails the task with
  a non-zero exit. Run it alone with `mix power_model.ingest validate`; flags:

    * `--update-baseline` — rewrite the topology golden file from this run
    * `--baseline PATH` — compare against (or write) a different golden file
    * `--data-dir PATH` — where the source files live (default `data`)
  """

  use Mix.Task

  @shortdoc "Ingest grid data from public datasets"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["substations", "--api"] ->
        Mix.shell().info("Deriving substations from HIFLD API...")
        PowerModel.Ingestion.derive_substations_from_api()
        Mix.shell().info("Done.")

      ["substations"] ->
        ingest_substations_default()

      ["substations", path] ->
        Mix.shell().info("Ingesting substations from #{path}...")
        PowerModel.Ingestion.ingest_substations(path)
        Mix.shell().info("Done.")

      ["transmission_lines", "--api"] ->
        Mix.shell().info("Ingesting transmission lines from HIFLD API...")
        PowerModel.Ingestion.ingest_transmission_lines_from_api()
        Mix.shell().info("Done.")

      ["transmission_lines"] ->
        ingest_lines_default()

      ["transmission_lines", path] ->
        Mix.shell().info("Ingesting transmission lines from #{path}...")
        PowerModel.Ingestion.ingest_transmission_lines(path)
        Mix.shell().info("Done.")

      ["prepare_eia860"] ->
        prepare_eia860!()

      ["augment_levels"] ->
        Mix.shell().info("Merging terminating-line voltages into substation levels...")
        result = PowerModel.Ingestion.HIFLD.Substations.augment_voltage_levels_from_lines()
        Mix.shell().info("Done: #{inspect(result)}")

      ["hvdc_ties"] ->
        Mix.shell().info("Upserting curated HVDC ties...")
        {:ok, result} = PowerModel.Ingestion.HvdcTies.run()
        Mix.shell().info("Done: #{inspect(result)}")

      ["connectivity_repair"] ->
        Mix.shell().info("Repairing network connectivity (ROADMAP item 12)...")
        result = PowerModel.Ingestion.BusMapper.repair_connectivity()
        Mix.shell().info("Done: #{inspect(result)}")

      ["generators", path] ->
        Mix.shell().info("Ingesting generators from #{path}...")
        PowerModel.Ingestion.ingest_generators(path)
        Mix.shell().info("Done.")

      ["capacity_factors", path] ->
        Mix.shell().info("Updating capacity factors from #{path}...")
        PowerModel.Ingestion.EIA.Form923.ingest(path)
        Mix.shell().info("Done.")

      ["egrid", path] ->
        Mix.shell().info("Ingesting eGRID data from #{path}...")
        PowerModel.Ingestion.EPA.EGrid.ingest(path)
        Mix.shell().info("Done.")

      ["map_buses"] ->
        Mix.shell().info("Mapping components to buses...")
        PowerModel.Ingestion.map_buses()
        Mix.shell().info("Done.")

      ["estimate_parameters"] ->
        Mix.shell().info("Estimating electrical parameters...")
        PowerModel.Ingestion.estimate_parameters()
        Mix.shell().info("Done.")

      ["estimate_loads"] ->
        Mix.shell().info("Estimating loads...")
        PowerModel.Ingestion.estimate_loads()
        Mix.shell().info("Done.")

      ["international"] ->
        Mix.shell().info("Creating international connections (US-Canada, US-Mexico)...")
        PowerModel.Ingestion.ingest_international_connections()
        Mix.shell().info("Done.")

      ["cleanup"] ->
        Mix.shell().info("Cleaning up synthetic/demo components...")
        PowerModel.Ingestion.Cleanup.run()
        Mix.shell().info("Done.")

      ["water", "san_diego"] ->
        Mix.shell().info("Ingesting San Diego County water infrastructure...")
        PowerModel.Ingestion.Water.SanDiego.ingest()
        Mix.shell().info("Done.")

      ["map_water_grid"] ->
        Mix.shell().info("Mapping water facilities to nearest grid buses...")
        {mapped, loads} = PowerModel.Grid.map_water_facilities_to_grid()
        Mix.shell().info("Mapped #{mapped} facilities, created #{loads} load records.")
        Mix.shell().info("Done.")

      ["datacenters"] ->
        Mix.shell().info("Ingesting curated datacenter dataset...")
        PowerModel.Ingestion.ingest_datacenters()
        Mix.shell().info("Done.")

      ["map_datacenters"] ->
        Mix.shell().info("Mapping datacenters to nearest grid buses...")
        {mapped, loads, unmapped} = PowerModel.Grid.map_datacenters_to_grid()

        Mix.shell().info(
          "Mapped #{mapped} datacenters (#{unmapped} unmapped), " <>
            "#{loads} flat load rows created."
        )

        Mix.shell().info("Done.")

      ["map_bas"] ->
        Mix.shell().info("Mapping balancing authorities from data/...")
        PowerModel.Ingestion.map_balancing_authorities("data")
        Mix.shell().info("Done.")

      ["map_bas", path] ->
        Mix.shell().info("Mapping balancing authorities from #{path}...")
        PowerModel.Ingestion.map_balancing_authorities(path)
        Mix.shell().info("Done.")

      ["demand"] ->
        Mix.shell().info("Ingesting EIA-930 demand from data/...")
        PowerModel.Ingestion.ingest_demand("data")
        Mix.shell().info("Done.")

      ["demand", path] ->
        Mix.shell().info("Ingesting EIA-930 demand from #{path}...")
        PowerModel.Ingestion.ingest_demand(path)
        Mix.shell().info("Done.")

      ["population"] ->
        Mix.shell().info("Ingesting Census county population from data/...")
        PowerModel.Ingestion.ingest_population("data")
        Mix.shell().info("Done.")

      ["population", path] ->
        Mix.shell().info("Ingesting Census county population from #{path}...")
        PowerModel.Ingestion.ingest_population(path)
        Mix.shell().info("Done.")

      ["btm_solar"] ->
        Mix.shell().info("Ingesting EIA-861 behind-the-meter solar from data/...")
        PowerModel.Ingestion.EIA.Form861.run("data")
        Mix.shell().info("Done.")

      ["btm_solar", path] ->
        Mix.shell().info("Ingesting EIA-861 behind-the-meter solar from #{path}...")
        PowerModel.Ingestion.EIA.Form861.run(path)
        Mix.shell().info("Done.")

      ["backfill_hifld_fields"] ->
        Mix.shell().info("Backfilling HIFLD fields (TYPE, OWNER, SUB_1, SUB_2) from API...")
        PowerModel.Ingestion.HIFLD.TransmissionLines.backfill_hifld_fields()
        Mix.shell().info("Done.")

      ["validate" | flags] ->
        run_validation(flags)

      ["full_pipeline"] ->
        run_full_pipeline()

      _ ->
        Mix.shell().error("""
        Usage:
          mix power_model.ingest substations [<path> | --api]
          mix power_model.ingest transmission_lines [<path> | --api]
          mix power_model.ingest prepare_eia860
          mix power_model.ingest generators <path>
          mix power_model.ingest capacity_factors <path>
          mix power_model.ingest egrid <path>
          mix power_model.ingest map_buses
          mix power_model.ingest augment_levels
          mix power_model.ingest hvdc_ties
          mix power_model.ingest connectivity_repair
          mix power_model.ingest estimate_parameters
          mix power_model.ingest estimate_loads
          mix power_model.ingest map_bas [<path>]
          mix power_model.ingest demand [<path>]
          mix power_model.ingest international
          mix power_model.ingest cleanup
          mix power_model.ingest water san_diego
          mix power_model.ingest datacenters
          mix power_model.ingest map_datacenters
          mix power_model.ingest validate [--update-baseline] [--baseline <path>] [--data-dir <path>]
          mix power_model.ingest full_pipeline
        """)
    end
  end

  @vendored_dir "data/vendored"
  @vendored_lines_files [
    "hifld_next_transmission_lines_v1.geojsonl",
    "hifld_next_transmission_lines_v1.geojson"
  ]
  @vendored_substations_files ["hifld_substations_mirror_2021vintage.geojson"]

  @doc """
  Path to the vendored transmission-line snapshot, or nil when it has not been
  converted yet.
  """
  def vendored_lines_path do
    Enum.find_value(@vendored_lines_files, &existing_vendored/1)
  end

  @doc "Path to the vendored native substation layer, or nil."
  def vendored_substations_path do
    Enum.find_value(@vendored_substations_files, &existing_vendored/1)
  end

  defp existing_vendored(name) do
    path = Path.join(@vendored_dir, name)
    if File.regular?(path), do: path
  end

  defp ingest_lines_default do
    case vendored_lines_path() do
      nil ->
        Mix.raise("""
        No vendored transmission-line snapshot found in #{@vendored_dir}.

        Expected one of: #{Enum.join(@vendored_lines_files, ", ")}

        Convert the pinned GeoParquet first:

            python3 scripts/convert_vendored_hifld.py

        (needs pyarrow: `python3 -m pip install pyarrow`). Fetch URL and
        checksum are in data/vendored/PROVENANCE.md. To use the unofficial
        ArcGIS mirror instead, pass --api.
        """)

      path ->
        Mix.shell().info("Source: #{provenance(path, :lines)}")
        PowerModel.Ingestion.ingest_transmission_lines(path)
    end
  end

  defp ingest_substations_default do
    case vendored_substations_path() do
      nil ->
        Mix.raise("""
        No vendored substation layer found in #{@vendored_dir}.

        Expected: #{Enum.join(@vendored_substations_files, ", ")}
        (fetch URL and checksum in data/vendored/PROVENANCE.md)

        To derive substations from line endpoints instead — the fallback that
        invents yards at endpoint centroids — pass --api.
        """)

      path ->
        Mix.shell().info("Source: #{provenance(path, :substations)}")
        PowerModel.Ingestion.ingest_substations(path)
    end
  end

  # Recorded in the ingest output so a database can be traced back to the
  # snapshot it was built from (REVIEW DAT-19).
  defp provenance(path, kind) do
    size_mb = Float.round(File.stat!(path).size / 1_000_000, 1)

    label =
      case kind do
        :lines -> "HIFLD Next transmission lines, pinned 2026-08-15, public domain"
        :substations -> "HIFLD substations mirror, 2021 vintage, pinned 2026-08-15"
      end

    "#{path} (#{size_mb} MB) — #{label}; see data/vendored/PROVENANCE.md"
  end

  @eia860_csvs ["data/3_1_Generator_Y2024.csv", "data/2___Plant_Y2024.csv"]

  defp prepare_eia860! do
    Mix.shell().info("Preparing EIA-860 CSVs from data/eia860_2024.zip...")

    case System.cmd("python3", ["scripts/prepare_eia860.py"], stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info(output)
        :ok

      {output, status} ->
        Mix.raise("""
        scripts/prepare_eia860.py failed (exit #{status}):

        #{output}
        Needs openpyxl: `python3 -m pip install openpyxl`.
        """)
    end
  end

  # The generators stage reads CSVs EIA does not publish; extract them from
  # the zip first when they are missing, so `full_pipeline` on a clean
  # checkout is not a hidden manual step.
  defp prepare_eia860_if_needed do
    if Enum.all?(@eia860_csvs, &File.regular?/1) do
      {:ok, :already_present}
    else
      prepare_eia860!()
      {:ok, :prepared}
    end
  end

  # DAT-16 / PLT-11: the COMPLETE documented ingestion order. Every stage
  # runs, in dependency order, each printing its own result. File-based
  # stages read from data/ and raise if their inputs are missing rather than
  # silently producing a degenerate grid.
  # Public so the ordering constraints between stages can be asserted without
  # running a four-hour pipeline (REVIEW DAT-26).
  @doc false
  def pipeline_stages do
    [
      {"Ingesting transmission lines (vendored HIFLD Next snapshot)",
       fn -> ingest_lines_default() end},
      {"Ingesting substations (vendored native HIFLD layer)",
       fn -> ingest_substations_default() end},
      {"Preparing EIA-860 CSVs from the published zip", fn -> prepare_eia860_if_needed() end},
      {"Ingesting generators from EIA-860 (data/)",
       fn -> PowerModel.Ingestion.ingest_generators("data") end},
      {"Updating capacity factors from EIA-923 (data/)",
       fn -> PowerModel.Ingestion.EIA.Form923.ingest("data") end},
      {"Ingesting eGRID data (data/)", fn -> PowerModel.Ingestion.EPA.EGrid.ingest("data") end},
      # REVIEW DAT-26: the line pass runs BEFORE map_buses because
      # `map_generators_to_buses` ranks candidate buses on connected branch
      # capacity, which sums `rating_a_mva` — nil until this pass writes it.
      # On a fresh database that made 87.8% of the capability at generator
      # buses read as zero, and DR-4's placement rule fell through to the
      # pre-DR-4 nearest-any-level one it exists to replace.
      #
      # Only the LINE pass moves. It reads `length_km`, then the line's own
      # geometry, and only then its endpoint buses — and every line it owns
      # (HIFLD; matpower/international/connectivity_repair are externally
      # authored) carries geometry, so it never reaches the endpoints. Its two
      # siblings stay where they are: `synthesize_line_end_reactors` selects on
      # `from_bus_id`/`to_bus_id` being non-null and would find nothing here.
      {"Estimating line parameters (before bus mapping ranks on them)",
       fn -> PowerModel.Ingestion.ParameterEstimator.estimate_line_parameters() end},
      {"Mapping components to buses", fn -> PowerModel.Ingestion.map_buses() end},
      {"Creating international connections",
       fn -> PowerModel.Ingestion.ingest_international_connections() end},
      # Version-stamped, so the line pass above is not repeated: what runs here
      # is generator Q limits and the line-end reactors, which need endpoints.
      {"Estimating electrical parameters", fn -> PowerModel.Ingestion.estimate_parameters() end},
      {"Mapping balancing authorities (data/)",
       fn -> PowerModel.Ingestion.map_balancing_authorities("data") end},
      # After map_bas: the ties are placed per interconnection, and a bus's
      # interconnection is only trustworthy once its BA is known.
      {"Upserting curated HVDC ties", fn -> PowerModel.Ingestion.HvdcTies.run() end},
      {"Ingesting EIA-930 demand (data/)", fn -> PowerModel.Ingestion.ingest_demand("data") end},
      {"Ingesting Census county population (data/)",
       fn -> PowerModel.Ingestion.ingest_population("data") end},
      {"Estimating loads", fn -> PowerModel.Ingestion.estimate_loads() end},
      {"Ingesting San Diego water infrastructure",
       fn -> PowerModel.Ingestion.Water.SanDiego.ingest() end},
      {"Mapping water facilities to grid buses",
       fn -> PowerModel.Grid.map_water_facilities_to_grid() end},
      {"Ingesting curated datacenters", fn -> PowerModel.Ingestion.ingest_datacenters() end},
      {"Mapping datacenters to grid buses", fn -> PowerModel.Grid.map_datacenters_to_grid() end},
      {"Cleanup: re-mapping synthetic components", fn -> PowerModel.Ingestion.Cleanup.run() end},
      # ROADMAP item 12: runs after cleanup, so it sees the endpoints the
      # 50 km last-resort search recovered and joins only what is still apart.
      {"Repairing network connectivity",
       fn -> PowerModel.Ingestion.BusMapper.repair_connectivity() end},
      # REVIEW DAT-26: `map_generators_to_buses` is a FILL — it never revisits
      # a generator that already has a bus — so the plants placed before
      # cleanup and connectivity repair never see the branch capacity those
      # stages added. This is the re-map half, and it runs here for the same
      # reason migration 150003 ran last of the DR-4 set: the three stages
      # before it change the capacity term the rule ranks on. It moves a plant
      # only when its bus fails the rule AND the rule's pick is a strict
      # improvement, so re-running is a no-op. Until now it had no pipeline
      # caller at all: a fresh database got the fill and never the repair.
      {"Re-mapping stranded generators",
       fn -> PowerModel.Ingestion.BusMapper.remap_stranded_generators() end},
      # ROADMAP 2.5 item 30. Last of the data stages: it allocates onto the
      # PQ-buses-with-loads universe, so it must see the bus set that cleanup
      # and connectivity repair leave behind, not the one estimate_loads saw.
      {"Ingesting EIA-861 behind-the-meter solar (data/)",
       fn -> PowerModel.Ingestion.EIA.Form861.run("data") end},
      # ROADMAP Phase 0 item 3: the gates run LAST, on the data every earlier
      # stage just wrote, and fail the pipeline on a topology regression.
      {"Validating ingested data", fn -> run_validation([]) end}
    ]
  end

  # Shared by `mix power_model.ingest validate` and the final pipeline stage.
  # Prints the summary table either way; `Mix.raise` on failure gives the
  # non-zero exit a CI gate needs.
  defp run_validation(flags) do
    {parsed, _rest, invalid} =
      OptionParser.parse(flags,
        strict: [update_baseline: :boolean, baseline: :string, data_dir: :string]
      )

    if invalid != [] do
      Mix.raise(
        "Unknown validate option(s): #{Enum.map_join(invalid, ", ", fn {flag, _} -> flag end)}"
      )
    end

    opts =
      [update_baseline: Keyword.get(parsed, :update_baseline, false)]
      |> put_if(:baseline_path, parsed[:baseline])
      |> put_if(:data_dir, parsed[:data_dir])

    case PowerModel.Ingestion.Validation.run(opts) do
      {:ok, summary} ->
        Mix.shell().info("\n" <> PowerModel.Ingestion.Validation.summary_table(summary))
        summary.status

      {:error, summary} ->
        Mix.shell().error("\n" <> PowerModel.Ingestion.Validation.summary_table(summary))

        Mix.raise(
          "Ingest validation failed (#{length(summary.failures)} gate(s)). " <>
            "If the change is intended, re-run with --update-baseline and commit the new " <>
            "priv/topology_baseline.json alongside it."
        )
    end
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  defp run_full_pipeline do
    Mix.shell().info("=== Full Ingestion Pipeline ===\n")

    stages = pipeline_stages()
    total = length(stages)

    stages
    |> Enum.with_index(1)
    |> Enum.each(fn {{label, fun}, i} ->
      Mix.shell().info("\nStep #{i}/#{total}: #{label}...")
      result = fun.()
      Mix.shell().info("  -> #{inspect(result, limit: 5, printable_limit: 200)}")
    end)

    Mix.shell().info("\n=== Pipeline Complete ===")

    # Print summary
    alias PowerModel.Repo

    alias PowerModel.Grid.{
      BalancingAuthority,
      Bus,
      Datacenter,
      Generator,
      Load,
      Substation,
      Transformer,
      TransmissionLine,
      WaterFacility
    }

    import Ecto.Query

    Mix.shell().info("""

    Database Summary:
      Generators:         #{Repo.aggregate(Generator, :count)}
      Substations:        #{Repo.aggregate(Substation, :count)}
      Buses:              #{Repo.aggregate(Bus, :count)}
      Transmission Lines: #{Repo.aggregate(TransmissionLine, :count)}
      Transformers:       #{Repo.aggregate(Transformer, :count)}
      Loads:              #{Repo.aggregate(Load, :count)}
      Balancing Auths:    #{Repo.aggregate(BalancingAuthority, :count)}
      Water Facilities:   #{Repo.aggregate(WaterFacility, :count)}
      Datacenters:        #{Repo.aggregate(Datacenter, :count)}
      Lines with buses:   #{Repo.one(from tl in TransmissionLine, where: not is_nil(tl.from_bus_id) and not is_nil(tl.to_bus_id), select: count())}
      Gens with buses:    #{Repo.one(from g in Generator, where: not is_nil(g.bus_id), select: count())}
    """)
  end
end
