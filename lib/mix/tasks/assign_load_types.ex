defmodule Mix.Tasks.PowerModel.AssignLoadTypes do
  @moduledoc """
  Assign realistic ZIP load types based on bus voltage level heuristics.

  Each load is classified as "residential", "commercial", or "industrial"
  using the voltage level of its connected bus as a proxy for the type of
  service territory:

    - Distribution (< 69 kV):       60% residential, 25% commercial, 15% industrial
    - Sub-transmission (69-138 kV):  30% residential, 40% commercial, 30% industrial
    - Transmission (> 138 kV):       10% residential, 30% commercial, 60% industrial

  The load's `bus_id` is used as a deterministic seed so assignments are
  reproducible across runs.

  ## Usage

      mix power_model.assign_load_types
      mix power_model.assign_load_types --dry-run
  """

  use Mix.Task

  import Ecto.Query

  alias PowerModel.Repo
  alias PowerModel.Grid.{Load, Bus}

  @shortdoc "Assign ZIP load types based on bus voltage level"

  @voltage_bands %{
    distribution: {["residential", "commercial", "industrial"], [0.60, 0.85, 1.00]},
    sub_transmission: {["residential", "commercial", "industrial"], [0.30, 0.70, 1.00]},
    transmission: {["residential", "commercial", "industrial"], [0.10, 0.40, 1.00]}
  }

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    dry_run = "--dry-run" in args

    # Fetch all loads with their bus voltage level
    loads_with_kv =
      from(l in Load, join: b in Bus, on: l.bus_id == b.id, select: {l.id, l.bus_id, b.base_kv})
      |> Repo.all()

    total = length(loads_with_kv)
    Mix.shell().info("Found #{total} loads to classify...")

    # Classify each load
    assignments =
      Enum.map(loads_with_kv, fn {load_id, bus_id, base_kv} ->
        band = voltage_band(base_kv)
        load_type = pick_type(bus_id, band)
        {load_id, load_type}
      end)

    # Count by type
    counts = Enum.frequencies_by(assignments, fn {_, t} -> t end)

    Mix.shell().info("""
    Classification results:
      Residential: #{Map.get(counts, "residential", 0)}
      Commercial:  #{Map.get(counts, "commercial", 0)}
      Industrial:  #{Map.get(counts, "industrial", 0)}
    """)

    if dry_run do
      Mix.shell().info("Dry run — no database changes made.")
    else
      # Batch update in chunks of 1000
      assignments
      |> Enum.chunk_every(1000)
      |> Enum.with_index(1)
      |> Enum.each(fn {chunk, batch_num} ->
        Repo.transaction(fn ->
          Enum.each(chunk, fn {load_id, load_type} ->
            from(l in Load, where: l.id == ^load_id)
            |> Repo.update_all(set: [load_type: load_type])
          end)
        end)

        if rem(batch_num, 5) == 0 do
          Mix.shell().info("  Updated #{batch_num * 1000} / #{total}...")
        end
      end)

      Mix.shell().info("Done. Updated #{total} loads.")
    end
  end

  @doc false
  def voltage_band(nil), do: :distribution
  def voltage_band(kv) when kv < 69.0, do: :distribution
  def voltage_band(kv) when kv <= 138.0, do: :sub_transmission
  def voltage_band(_kv), do: :transmission

  @doc """
  Deterministically pick a load type based on bus_id and voltage band.

  Uses the bus_id as a seed into :erlang.phash2 so that the same bus always
  gets the same classification (reproducible without external state).
  """
  def pick_type(bus_id, band) do
    {types, cumulative} = Map.fetch!(@voltage_bands, band)

    # Deterministic pseudo-random value in [0, 1) from bus_id
    hash = :erlang.phash2(bus_id, 1_000_000)
    r = hash / 1_000_000

    pick_from_cdf(types, cumulative, r)
  end

  defp pick_from_cdf([type | _], [threshold | _], r) when r < threshold, do: type
  defp pick_from_cdf([_ | types], [_ | thresholds], r), do: pick_from_cdf(types, thresholds, r)
  defp pick_from_cdf([type], _, _r), do: type
end
