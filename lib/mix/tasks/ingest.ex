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
      mix power_model.ingest full_pipeline
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

      ["substations", "--rutgers"] ->
        Mix.shell().info("Ingesting substations from Rutgers HIFLD mirror...")
        {:ok, result} = PowerModel.Ingestion.HIFLD.Substations.ingest_from_rutgers()
        Mix.shell().info("Done. Enriched: #{result.enriched}, New: #{result.inserted}")

      ["substations", "--osm"] ->
        Mix.shell().info("Ingesting substations from OpenStreetMap Overpass API...")
        {:ok, result} = PowerModel.Ingestion.OSM.Substations.ingest()

        Mix.shell().info(
          "Done. Enriched: #{result.enriched}, New: #{result.inserted}, Failed states: #{result.failed_states}"
        )

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

      ["water", "nationwide"] ->
        Mix.shell().info("Ingesting nationwide water infrastructure...")
        PowerModel.Ingestion.Water.Nationwide.ingest_all()
        Mix.shell().info("Done.")

      ["water", "wastewater"] ->
        Mix.shell().info("Ingesting EPA wastewater treatment plants...")
        PowerModel.Ingestion.Water.Nationwide.ingest_epa_wastewater()
        Mix.shell().info("Done.")

      ["water", "dams"] ->
        Mix.shell().info("Ingesting USACE National Inventory of Dams...")
        PowerModel.Ingestion.Water.Nationwide.ingest_dams()
        Mix.shell().info("Done.")

      ["water", "drinking_water"] ->
        Mix.shell().info("Ingesting EPA drinking water systems...")
        PowerModel.Ingestion.Water.Nationwide.ingest_drinking_water()
        Mix.shell().info("Done.")

      ["map_water_grid"] ->
        Mix.shell().info("Mapping water facilities to nearest grid buses...")
        {mapped, loads} = PowerModel.Grid.map_water_facilities_to_grid()
        Mix.shell().info("Mapped #{mapped} facilities, created #{loads} load records.")
        Mix.shell().info("Done.")

      ["backfill_hifld_fields"] ->
        Mix.shell().info("Backfilling HIFLD fields (TYPE, OWNER, SUB_1, SUB_2) from API...")
        PowerModel.Ingestion.HIFLD.TransmissionLines.backfill_hifld_fields()
        Mix.shell().info("Done.")

      ["eia_hourly"] ->
        Mix.shell().info("Ingesting EIA hourly grid data (full year, all BAs)...")
        {:ok, total} = PowerModel.Ingestion.EIA.HourlyGrid.ingest_demand()
        Mix.shell().info("Demand: #{total} records")
        {:ok, total2} = PowerModel.Ingestion.EIA.HourlyGrid.ingest_generation_mix()
        Mix.shell().info("Generation mix: #{total2} records. Done.")

      ["eia_hourly", "--sample"] ->
        Mix.shell().info("Ingesting EIA sample data (4 representative weeks, 10 major BAs)...")
        {:ok, total} = PowerModel.Ingestion.EIA.HourlyGrid.ingest_sample()
        Mix.shell().info("Done. #{total} records.")

      ["fix_self_loops"] ->
        Mix.shell().info("Fixing self-loop transmission lines...")
        {:ok, result} = PowerModel.Ingestion.SelfLoopFix.run()

        Mix.shell().info(
          "Before: #{result.before}, Fixed: #{result.fixed}, Remaining: #{result.remaining}"
        )

      ["backfill_generator_dynamics"] ->
        Mix.shell().info(
          "Backfilling generator dynamic parameters (inertia, droop, ramp, cost)..."
        )

        PowerModel.Ingestion.GeneratorDefaults.backfill()
        Mix.shell().info("Done.")

      ["matpower", path | rest] ->
        opts = parse_matpower_opts(rest)
        Mix.shell().info("Importing MATPOWER case: #{path}")

        case PowerModel.Ingestion.Matpower.import(path, opts) do
          {:ok, result} ->
            Mix.shell().info("""
            Import complete:
              Buses:        #{result.buses}
              Generators:   #{result.generators}
              Lines:        #{result.lines}
              Transformers: #{result.transformers}
              Loads:        #{result.loads}
              Substations:  #{result.substations}
            """)

          {:error, reason} ->
            Mix.shell().error("Import failed: #{inspect(reason)}")
        end

      ["critical_facilities"] ->
        Mix.shell().info("Ingesting all critical facilities from HIFLD API...")
        PowerModel.Ingestion.HIFLD.CriticalFacilities.ingest_all()
        Mix.shell().info("Done.")

      ["critical_facilities", category]
      when category in ~w(hospital fire_station police_station ems_station) ->
        cat = String.to_atom(category)
        Mix.shell().info("Ingesting #{category} from HIFLD API...")
        PowerModel.Ingestion.HIFLD.CriticalFacilities.ingest(cat)
        Mix.shell().info("Done.")

      ["map_critical_facilities"] ->
        Mix.shell().info("Mapping critical facilities to nearest grid buses...")
        {mapped, loads} = PowerModel.Grid.map_critical_facilities_to_grid()
        Mix.shell().info("Mapped #{mapped} facilities, created #{loads} load records.")
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
          mix power_model.ingest international
          mix power_model.ingest cleanup
          mix power_model.ingest water san_diego
          mix power_model.ingest water nationwide
          mix power_model.ingest water wastewater
          mix power_model.ingest water dams
          mix power_model.ingest water drinking_water
          mix power_model.ingest substations --rutgers
          mix power_model.ingest substations --osm
          mix power_model.ingest eia_hourly
          mix power_model.ingest eia_hourly --sample
          mix power_model.ingest backfill_generator_dynamics
          mix power_model.ingest matpower <path.m> [--clear] [--interconnection NAME]
          mix power_model.ingest critical_facilities [hospital|fire_station|police_station|ems_station]
          mix power_model.ingest map_critical_facilities
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

  defp parse_matpower_opts(args) do
    parse_matpower_opts(args, [])
  end

  defp parse_matpower_opts([], acc), do: acc

  defp parse_matpower_opts(["--clear" | rest], acc) do
    parse_matpower_opts(rest, [{:clear_existing, true} | acc])
  end

  defp parse_matpower_opts(["--interconnection", name | rest], acc) do
    parse_matpower_opts(rest, [{:interconnection, name} | acc])
  end

  defp parse_matpower_opts([_ | rest], acc) do
    parse_matpower_opts(rest, acc)
  end
end
