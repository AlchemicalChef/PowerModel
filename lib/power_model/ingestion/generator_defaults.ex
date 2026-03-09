defmodule PowerModel.Ingestion.GeneratorDefaults do
  @moduledoc """
  Populates generator dynamic parameters (inertia, droop, governor time constant,
  ramp rate, marginal cost, AGC participation) from fuel_type and prime_mover lookups.
  """

  import Ecto.Query
  alias PowerModel.Repo
  alias PowerModel.Grid.Generator

  @inertia_h %{
    "NUC" => 6.0, "COL" => 4.5, "NG" => 3.5, "WAT" => 3.0,
    "WND" => 0.0, "SUN" => 0.0, "PET" => 3.0, "GEO" => 4.0,
    "BIT" => 4.5, "SUB" => 4.5, "LIG" => 4.0, "OG" => 3.5,
    "DFO" => 3.0, "RFO" => 3.5, "WH" => 3.0
  }

  @droop_pct %{
    "NUC" => 5.0, "COL" => 4.0, "NG" => 4.0, "WAT" => 3.0,
    "WND" => 0.0, "SUN" => 0.0
  }

  @gov_time_constant_s %{
    "NUC" => 0.5, "COL" => 0.3, "NG" => 0.2, "WAT" => 1.5,
    "WND" => 0.0, "SUN" => 0.0
  }

  @ramp_rate_mult %{
    "NUC" => 0.01, "COL" => 0.02, "NG" => 0.08, "WAT" => 0.5,
    "WND" => 1.0, "SUN" => 1.0
  }

  @marginal_cost %{
    "NUC" => 10.0, "COL" => 25.0, "WAT" => 5.0, "WND" => 0.0,
    "SUN" => 0.0, "PET" => 80.0, "GEO" => 5.0, "BIT" => 28.0,
    "SUB" => 22.0, "LIG" => 20.0, "OG" => 50.0, "DFO" => 90.0,
    "RFO" => 70.0, "WH" => 5.0
  }

  @ng_ct_movers MapSet.new(["CA", "CT"])
  @ng_cc_movers MapSet.new(["CC", "CS", "ST"])

  @doc """
  Returns a map of default dynamic parameters for a given fuel_type and p_max_mw.

  For NG generators, marginal cost depends on prime_mover (combustion turbine vs combined cycle).
  """
  def defaults_for(fuel_type, p_max_mw, prime_mover \\ nil) do
    fuel = fuel_type || ""
    p_max = p_max_mw || 0.0

    %{
      inertia_h: Map.get(@inertia_h, fuel, 3.0),
      droop_pct: Map.get(@droop_pct, fuel, 4.0),
      gov_time_constant_s: Map.get(@gov_time_constant_s, fuel, 0.3),
      ramp_rate_mw_per_min: p_max * Map.get(@ramp_rate_mult, fuel, 0.03),
      marginal_cost_per_mwh: marginal_cost_for(fuel, prime_mover)
    }
  end

  defp marginal_cost_for("NG", prime_mover) do
    cond do
      prime_mover != nil and MapSet.member?(@ng_ct_movers, prime_mover) -> 60.0
      prime_mover != nil and MapSet.member?(@ng_cc_movers, prime_mover) -> 35.0
      true -> 35.0
    end
  end

  defp marginal_cost_for(fuel, _prime_mover) do
    Map.get(@marginal_cost, fuel, 40.0)
  end

  @doc """
  Backfill all generators in the database with default dynamic parameters.

  Only updates generators that don't already have values set for these fields.
  After setting per-generator defaults, computes AGC participation factors
  for eligible units (droop > 0 and p_max > 20 MW).
  """
  def backfill do
    generators = Repo.all(Generator)
    total = length(generators)
    IO.puts("[GeneratorDefaults] Backfilling #{total} generators...")

    {updated, _} =
      Enum.reduce(generators, {0, 0}, fn gen, {count, _batch} ->
        defaults = defaults_for(gen.fuel_type, gen.p_max_mw, gen.prime_mover)

        attrs =
          defaults
          |> maybe_keep(:inertia_h, gen.inertia_h)
          |> maybe_keep(:droop_pct, gen.droop_pct)
          |> maybe_keep(:gov_time_constant_s, gen.gov_time_constant_s)
          |> maybe_keep(:ramp_rate_mw_per_min, gen.ramp_rate_mw_per_min)
          |> maybe_keep(:marginal_cost_per_mwh, gen.marginal_cost_per_mwh)

        if map_size(attrs) > 0 do
          gen
          |> Generator.changeset(attrs)
          |> Repo.update!()
          {count + 1, 0}
        else
          {count, 0}
        end
      end)

    IO.puts("[GeneratorDefaults] Updated #{updated} generators with defaults.")

    backfill_agc()

    :ok
  end

  defp backfill_agc do
    eligible =
      Repo.all(
        from g in Generator,
          where: g.droop_pct > 0.0 and g.p_max_mw > 20.0 and g.status == "in_service"
      )

    total_agc_capacity = Enum.sum(Enum.map(eligible, & &1.p_max_mw))

    if total_agc_capacity > 0 do
      Enum.each(eligible, fn gen ->
        factor = gen.p_max_mw / total_agc_capacity

        gen
        |> Generator.changeset(%{agc_participation_factor: factor})
        |> Repo.update!()
      end)

      IO.puts("[GeneratorDefaults] Set AGC participation for #{length(eligible)} generators (total capacity: #{Float.round(total_agc_capacity, 1)} MW)")
    else
      IO.puts("[GeneratorDefaults] No AGC-eligible generators found.")
    end
  end

  defp maybe_keep(attrs, key, existing_value) do
    if existing_value == nil do
      attrs
    else
      Map.delete(attrs, key)
    end
  end
end
