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

  # Nuclear plants do not provide upward governor response (NRC regulations);
  # droop 0.0 disables their participation in frequency response.
  @droop_pct %{
    "NUC" => 0.0, "COL" => 4.0, "NG" => 4.0, "WAT" => 3.0,
    "WND" => 0.0, "SUN" => 0.0
  }

  # Governor time constants represent effective mechanical power delivery time,
  # not just servo response. Includes boiler/turbine/water column dynamics.
  @gov_time_constant_s %{
    "NUC" => 999.0, "COL" => 8.0, "NG" => 1.5, "WAT" => 3.0,
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

  # p_min as fraction of p_max when EIA Minimum Load data is missing
  @p_min_fraction %{
    "NUC" => 1.0,   # nuclear runs at 100% or is offline
    "COL" => 0.35,  # coal minimum stable load ~35%
    "NG"  => 0.30,  # gas CT ~30%, CC ~40% (use 30% conservative)
    "WAT" => 0.10,  # hydro ~10%
    "WND" => 0.0,
    "SUN" => 0.0,
    "PET" => 0.25,
    "GEO" => 0.70,  # geothermal baseload, high minimum
    "BIT" => 0.35,
    "SUB" => 0.35,
    "LIG" => 0.35,
    "OG"  => 0.30,
    "DFO" => 0.25,
    "RFO" => 0.30,
    "WH"  => 0.10
  }

  # Transient stability defaults by fuel type
  @x_d_prime %{
    "NUC" => 0.20, "COL" => 0.25, "NG" => 0.30, "WAT" => 0.35,
    "WND" => 0.0, "SUN" => 0.0, "PET" => 0.30, "GEO" => 0.25,
    "BIT" => 0.25, "SUB" => 0.25, "LIG" => 0.25, "OG" => 0.30,
    "DFO" => 0.30, "RFO" => 0.30, "WH" => 0.35
  }

  @x_d %{
    "NUC" => 1.10, "COL" => 1.00, "NG" => 1.20, "WAT" => 0.90,
    "WND" => 0.0, "SUN" => 0.0, "PET" => 1.20, "GEO" => 1.00,
    "BIT" => 1.00, "SUB" => 1.00, "LIG" => 1.00, "OG" => 1.20,
    "DFO" => 1.20, "RFO" => 1.20, "WH" => 0.90
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

    gov_time = gov_time_for_fuel_and_mover(fuel, prime_mover)
    inertia = inertia_for_fuel_and_mover(fuel, prime_mover)

    %{
      inertia_h: inertia,
      droop_pct: Map.get(@droop_pct, fuel, 4.0),
      gov_time_constant_s: gov_time,
      ramp_rate_mw_per_min: p_max * Map.get(@ramp_rate_mult, fuel, 0.03),
      marginal_cost_per_mwh: marginal_cost_for(fuel, prime_mover),
      p_min_mw: p_max * Map.get(@p_min_fraction, fuel, 0.25),
      x_d_pu: Map.get(@x_d, fuel, 1.0),
      x_d_prime_pu: Map.get(@x_d_prime, fuel, 0.30),
      d_factor: 2.0,
      mva_base: p_max * 1.1
    }
  end

  defp gov_time_for_fuel_and_mover("NG", pm) when pm in ["CC", "CS"], do: 5.0
  defp gov_time_for_fuel_and_mover(fuel, _pm), do: Map.get(@gov_time_constant_s, fuel, 1.5)

  defp inertia_for_fuel_and_mover("NG", pm) when pm in ["CC", "CS"], do: 5.0
  defp inertia_for_fuel_and_mover(fuel, _pm), do: Map.get(@inertia_h, fuel, 3.0)

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
