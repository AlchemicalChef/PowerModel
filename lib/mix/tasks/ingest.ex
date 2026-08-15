defmodule Mix.Tasks.PowerModel.Ingest do
  @moduledoc """
  Ingest grid data from public datasets.

  ## Usage

      mix power_model.ingest substations /path/to/hifld/
      mix power_model.ingest substations --api
      mix power_model.ingest transmission_lines /path/to/hifld/
      mix power_model.ingest transmission_lines --api
      mix power_model.ingest generators /path/to/eia860/
      mix power_model.ingest capacity_factors /path/to/eia923/
      mix power_model.ingest egrid /path/to/egrid/
      mix power_model.ingest map_buses
      mix power_model.ingest estimate_parameters
      mix power_model.ingest estimate_loads
      mix power_model.ingest map_bas [/path/to/egrid/]   # balancing authorities + bus assignment
      mix power_model.ingest demand [/path/to/eia930/]   # EIA-930 hourly demand profiles
      mix power_model.ingest population [/path/to/census/]  # county population (load weights)
      mix power_model.ingest validate [--update-baseline] # ingest-time validation gates
      mix power_model.ingest full_pipeline    # runs EVERY documented step in order

  Demand data pipeline (after the grid is built): `egrid` -> `map_bas` ->
  `demand` -> `population` -> `estimate_loads`. Download EIA930_BALANCE_*.csv
  bulk files from https://www.eia.gov/electricity/gridmonitor, plus
  co-est*-alldata.csv (Census PEP county totals) and
  *_Gaz_counties_national.txt (Census Gazetteer) into data/ first.

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

      ["substations", path] ->
        Mix.shell().info("Ingesting substations from #{path}...")
        PowerModel.Ingestion.ingest_substations(path)
        Mix.shell().info("Done.")

      ["transmission_lines", "--api"] ->
        Mix.shell().info("Ingesting transmission lines from HIFLD API...")
        PowerModel.Ingestion.ingest_transmission_lines_from_api()
        Mix.shell().info("Done.")

      ["transmission_lines", path] ->
        Mix.shell().info("Ingesting transmission lines from #{path}...")
        PowerModel.Ingestion.ingest_transmission_lines(path)
        Mix.shell().info("Done.")

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
          mix power_model.ingest substations <path | --api>
          mix power_model.ingest transmission_lines <path | --api>
          mix power_model.ingest generators <path>
          mix power_model.ingest capacity_factors <path>
          mix power_model.ingest egrid <path>
          mix power_model.ingest map_buses
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

  # DAT-16 / PLT-11: the COMPLETE documented ingestion order. Every stage
  # runs, in dependency order, each printing its own result. File-based
  # stages read from data/ and raise if their inputs are missing rather than
  # silently producing a degenerate grid.
  defp pipeline_stages do
    [
      {"Ingesting transmission lines from HIFLD API",
       fn -> PowerModel.Ingestion.ingest_transmission_lines_from_api() end},
      {"Deriving substations from transmission line data",
       fn -> PowerModel.Ingestion.derive_substations_from_api() end},
      {"Ingesting generators from EIA-860 (data/)",
       fn -> PowerModel.Ingestion.ingest_generators("data") end},
      {"Updating capacity factors from EIA-923 (data/)",
       fn -> PowerModel.Ingestion.EIA.Form923.ingest("data") end},
      {"Ingesting eGRID data (data/)", fn -> PowerModel.Ingestion.EPA.EGrid.ingest("data") end},
      {"Mapping components to buses", fn -> PowerModel.Ingestion.map_buses() end},
      {"Creating international connections",
       fn -> PowerModel.Ingestion.ingest_international_connections() end},
      {"Estimating electrical parameters", fn -> PowerModel.Ingestion.estimate_parameters() end},
      {"Mapping balancing authorities (data/)",
       fn -> PowerModel.Ingestion.map_balancing_authorities("data") end},
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
