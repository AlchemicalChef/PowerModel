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
      mix power_model.ingest full_pipeline    # runs all API-based steps in order

  Demand data pipeline (after the grid is built): `egrid` -> `map_bas` ->
  `demand` -> `estimate_loads`. Download EIA930_BALANCE_*.csv bulk files from
  https://www.eia.gov/electricity/gridmonitor into data/ first.
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

      ["backfill_hifld_fields"] ->
        Mix.shell().info("Backfilling HIFLD fields (TYPE, OWNER, SUB_1, SUB_2) from API...")
        PowerModel.Ingestion.HIFLD.TransmissionLines.backfill_hifld_fields()
        Mix.shell().info("Done.")

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
          mix power_model.ingest full_pipeline
        """)
    end
  end

  defp run_full_pipeline do
    Mix.shell().info("=== Full Ingestion Pipeline ===\n")

    Mix.shell().info("Step 1/6: Ingesting transmission lines from HIFLD API...")
    PowerModel.Ingestion.ingest_transmission_lines_from_api()

    Mix.shell().info("\nStep 2/6: Deriving substations from transmission line data...")
    PowerModel.Ingestion.derive_substations_from_api()

    Mix.shell().info("\nStep 3/6: Mapping components to buses...")
    PowerModel.Ingestion.map_buses()

    Mix.shell().info("\nStep 4/6: Creating international connections...")
    PowerModel.Ingestion.ingest_international_connections()

    Mix.shell().info("\nStep 5/6: Estimating electrical parameters...")
    PowerModel.Ingestion.estimate_parameters()

    Mix.shell().info("\nStep 6/6: Estimating loads...")
    PowerModel.Ingestion.estimate_loads()

    Mix.shell().info("\n=== Pipeline Complete ===")

    # Print summary
    alias PowerModel.Repo
    alias PowerModel.Grid.{Bus, Generator, TransmissionLine, Substation, Transformer, Load}
    import Ecto.Query

    Mix.shell().info("""

    Database Summary:
      Generators:         #{Repo.aggregate(Generator, :count)}
      Substations:        #{Repo.aggregate(Substation, :count)}
      Buses:              #{Repo.aggregate(Bus, :count)}
      Transmission Lines: #{Repo.aggregate(TransmissionLine, :count)}
      Transformers:       #{Repo.aggregate(Transformer, :count)}
      Loads:              #{Repo.aggregate(Load, :count)}
      Lines with buses:   #{Repo.one(from tl in TransmissionLine, where: not is_nil(tl.from_bus_id) and not is_nil(tl.to_bus_id), select: count())}
      Gens with buses:    #{Repo.one(from g in Generator, where: not is_nil(g.bus_id), select: count())}
    """)
  end
end
