defmodule Mix.Tasks.PowerModel.FixImpedances do
  @moduledoc """
  Fixes impedance data quality issues in the power grid database.

  Addresses three categories of problems:

  1. **Zero-impedance bus ties**: MATPOWER branches with x=0 are connectivity-only
     elements (bus ties). The importer clamped these to x=0.0001, which creates
     susceptance of 10,000 pu and phantom flows of tens of GW. This task raises
     the minimum to x=0.01 (b=100) — still very low impedance for a strong
     connection, but not a numerical bomb.

  2. **Tiny impedances**: Transformers and lines with |x_pu| < 0.001 are typically
     3-winding star-point models or very short bus connections. These create
     unrealistically large susceptances. The task clamps |x_pu| >= 0.001 while
     preserving the sign (negative x is valid for star-point models).

  3. **Undersized transformer ratings**: When a transformer's MATPOWER rateA is
     far smaller than the power flow it actually carries (common for star-point
     legs), the rating is clearly wrong. The task sets ratings based on the
     connected bus voltage level for transformers with |x_pu| < 0.005, where
     the original rateA is most likely to be wrong.

  ## Usage

      mix power_model.fix_impedances           # Fix all issues
      mix power_model.fix_impedances --report   # Report only, no changes
      mix power_model.fix_impedances --dry-run  # Same as --report
  """

  use Mix.Task

  import Ecto.Query

  alias PowerModel.Repo
  alias PowerModel.Grid.{Transformer, TransmissionLine}

  @shortdoc "Fix impedance data quality issues (zero-x bus ties, tiny impedances, bad ratings)"

  # Minimum reactance for bus-tie branches (MATPOWER zero-impedance branches).
  # x=0.01 gives b=100 — a strong connection without numerical issues.
  @min_x_bus_tie 0.01

  # Minimum reactance for all other branches.
  # x=0.001 gives b=1000 — already very low, but physically plausible for
  # short connections and star-point legs.
  @min_x_branch 0.001

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    report_only = "--report" in args or "--dry-run" in args

    if report_only do
      Mix.shell().info("=== DRY RUN — no changes will be made ===\n")
    end

    report = generate_report()
    print_report(report)

    unless report_only do
      Mix.shell().info("\n=== Applying fixes ===\n")

      xfmr_fixed = fix_transformer_impedances()
      Mix.shell().info("Fixed #{xfmr_fixed} transformer impedances.")

      line_fixed = fix_line_impedances()
      Mix.shell().info("Fixed #{line_fixed} line impedances.")

      rating_fixed = fix_transformer_ratings()
      Mix.shell().info("Fixed #{rating_fixed} transformer ratings.")

      # Clear the grid snapshot cache so the fixes take effect
      PowerModel.Grid.clear_snapshot_cache()

      Mix.shell().info("\nDone. Transformer impedances: #{xfmr_fixed}, Line impedances: #{line_fixed}, Transformer ratings: #{rating_fixed}")
      Mix.shell().info("Grid snapshot cache cleared.")
    end
  end

  # ---------------------------------------------------------------------------
  # Report generation
  # ---------------------------------------------------------------------------

  @doc """
  Generate a data quality report for impedances.
  Returns a map with statistics and lists of problematic components.
  """
  def generate_report do
    transformers = Repo.all(from(t in Transformer, where: t.status == "in_service"))
    lines = Repo.all(from(l in TransmissionLine, where: l.status == "in_service"))

    %{
      transformers: %{
        total: length(transformers),
        zero_x_clamped: count_where(transformers, fn t -> t.x_pu == 0.0001 end),
        tiny_x: count_where(transformers, fn t -> abs(t.x_pu) < @min_x_branch and t.x_pu != 0.0001 end),
        negative_x: count_where(transformers, fn t -> t.x_pu < 0 end),
        x_distribution: impedance_histogram(transformers),
        worst_tiny: transformers
          |> Enum.filter(fn t -> abs(t.x_pu) < @min_x_branch end)
          |> Enum.sort_by(fn t -> abs(t.x_pu) end)
          |> Enum.take(10)
          |> Enum.map(fn t -> %{id: t.id, x_pu: t.x_pu, rated_mva: t.rated_mva, tap: t.tap_ratio} end),
        small_rating_count: count_where(transformers, fn t ->
          abs(t.x_pu) < 0.005 and t.rated_mva < voltage_based_rating(t)
        end)
      },
      lines: %{
        total: length(lines),
        zero_x_clamped: count_where(lines, fn l -> l.x_pu == 0.0001 end),
        tiny_x: count_where(lines, fn l -> l.x_pu != nil and abs(l.x_pu) < @min_x_branch and l.x_pu != 0.0001 end),
        x_distribution: impedance_histogram(lines),
        worst_tiny: lines
          |> Enum.filter(fn l -> l.x_pu != nil and abs(l.x_pu) < @min_x_branch end)
          |> Enum.sort_by(fn l -> abs(l.x_pu) end)
          |> Enum.take(10)
          |> Enum.map(fn l -> %{id: l.id, x_pu: l.x_pu, rating_a_mva: l.rating_a_mva, voltage_kv: l.voltage_kv} end)
      }
    }
  end

  defp impedance_histogram(components) do
    bins = [{0, 0.001}, {0.001, 0.005}, {0.005, 0.01}, {0.01, 0.05},
            {0.05, 0.1}, {0.1, 0.5}, {0.5, 1.0}, {1.0, 10.0}]

    Map.new(bins, fn {lo, hi} ->
      count = Enum.count(components, fn c ->
        x = Map.get(c, :x_pu) || 0.0
        abs(x) >= lo and abs(x) < hi
      end)
      {"#{lo}-#{hi}", count}
    end)
  end

  defp count_where(list, pred), do: Enum.count(list, pred)

  defp print_report(report) do
    Mix.shell().info("=== Impedance Data Quality Report ===\n")

    t = report.transformers
    Mix.shell().info("TRANSFORMERS (#{t.total} total):")
    Mix.shell().info("  Zero-x (clamped to 0.0001):   #{t.zero_x_clamped}")
    Mix.shell().info("  Tiny |x| < #{@min_x_branch}:            #{t.tiny_x}")
    Mix.shell().info("  Negative x (star-points):      #{t.negative_x}")
    Mix.shell().info("  Undersized ratings:            #{t.small_rating_count}")

    Mix.shell().info("\n  |x_pu| distribution:")
    for {range, count} <- Enum.sort(t.x_distribution) do
      bar = String.duplicate("#", min(count, 60))
      Mix.shell().info("    #{String.pad_trailing(range, 12)} #{String.pad_leading("#{count}", 5)} #{bar}")
    end

    if t.worst_tiny != [] do
      Mix.shell().info("\n  Worst tiny-x transformers:")
      for w <- t.worst_tiny do
        Mix.shell().info("    Xfmr #{w.id}: x=#{w.x_pu}, rated=#{w.rated_mva}MVA, tap=#{w.tap}")
      end
    end

    l = report.lines
    Mix.shell().info("\nLINES (#{l.total} total):")
    Mix.shell().info("  Zero-x (clamped to 0.0001):   #{l.zero_x_clamped}")
    Mix.shell().info("  Tiny |x| < #{@min_x_branch}:            #{l.tiny_x}")

    Mix.shell().info("\n  |x_pu| distribution:")
    for {range, count} <- Enum.sort(l.x_distribution) do
      bar = String.duplicate("#", min(count, 60))
      Mix.shell().info("    #{String.pad_trailing(range, 12)} #{String.pad_leading("#{count}", 5)} #{bar}")
    end
  end

  # ---------------------------------------------------------------------------
  # Fix transformer impedances
  # ---------------------------------------------------------------------------

  defp fix_transformer_impedances do
    transformers = Repo.all(from(t in Transformer, where: t.status == "in_service"))

    Enum.reduce(transformers, 0, fn xfmr, count ->
      x = xfmr.x_pu
      abs_x = abs(x)

      new_x = cond do
        # Zero-impedance bus ties (MATPOWER x=0 clamped to 0.0001)
        x == 0.0001 -> @min_x_bus_tie

        # Tiny positive impedance
        x > 0 and x < @min_x_branch -> @min_x_branch

        # Tiny negative impedance (preserve sign for star-point models)
        x < 0 and abs_x < @min_x_branch -> -@min_x_branch

        # Already OK
        true -> nil
      end

      if new_x do
        # Also fix r_pu if it was clamped along with x
        new_r = if xfmr.r_pu == 0.0001, do: abs(new_x) * 0.005, else: xfmr.r_pu

        xfmr
        |> Transformer.changeset(%{x_pu: new_x, r_pu: new_r})
        |> Repo.update!()

        count + 1
      else
        count
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Fix line impedances
  # ---------------------------------------------------------------------------

  defp fix_line_impedances do
    lines = Repo.all(from(l in TransmissionLine,
      where: l.status == "in_service" and not is_nil(l.x_pu)))

    Enum.reduce(lines, 0, fn line, count ->
      x = line.x_pu

      new_x = cond do
        x == 0.0001 -> @min_x_bus_tie
        x > 0 and x < @min_x_branch -> @min_x_branch
        true -> nil
      end

      if new_x do
        line
        |> TransmissionLine.changeset(%{x_pu: new_x})
        |> Repo.update!()

        count + 1
      else
        count
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Fix transformer ratings
  # ---------------------------------------------------------------------------

  defp fix_transformer_ratings do
    # For transformers with very low impedance, the MATPOWER rateA is often
    # a nominal value that's far too small for the actual power transfer.
    # We fix ratings for transformers where |x| < 0.005 (high-susceptance
    # branches most prone to large flows).
    transformers = Repo.all(
      from(t in Transformer,
        where: t.status == "in_service",
        preload: [:from_bus, :to_bus])
    )

    Enum.reduce(transformers, 0, fn xfmr, count ->
      appropriate_rating = voltage_based_rating_from_buses(xfmr.from_bus, xfmr.to_bus)

      # Only fix if current rating is significantly smaller than voltage-appropriate
      if abs(xfmr.x_pu) < 0.005 and xfmr.rated_mva < appropriate_rating * 0.8 do
        xfmr
        |> Transformer.changeset(%{rated_mva: appropriate_rating})
        |> Repo.update!()

        count + 1
      else
        count
      end
    end)
  end

  defp voltage_based_rating_from_buses(from_bus, to_bus) do
    from_kv = if from_bus, do: from_bus.base_kv || 0, else: 0
    to_kv = if to_bus, do: to_bus.base_kv || 0, else: 0
    max_kv = max(from_kv, to_kv)
    voltage_class_rating(max_kv)
  end

  # Voltage-based rating for transformers without bus preloads.
  # Uses a conservative lookup from the rated_mva as a proxy for voltage class.
  defp voltage_based_rating(xfmr) do
    # Without bus info, estimate from the rated_mva itself.
    # This is used only for the report count — actual fixes use bus voltages.
    cond do
      xfmr.rated_mva >= 800 -> 2000.0
      xfmr.rated_mva >= 400 -> 1000.0
      xfmr.rated_mva >= 200 -> 600.0
      xfmr.rated_mva >= 100 -> 400.0
      true -> 200.0
    end
  end

  defp voltage_class_rating(max_kv) do
    cond do
      max_kv >= 500 -> 2000.0
      max_kv >= 345 -> 1500.0
      max_kv >= 230 -> 1000.0
      max_kv >= 138 -> 600.0
      max_kv >= 115 -> 400.0
      max_kv >= 69 -> 200.0
      true -> 100.0
    end
  end
end
