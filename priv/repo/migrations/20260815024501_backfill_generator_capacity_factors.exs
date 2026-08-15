defmodule PowerModel.Repo.Migrations.BackfillGeneratorCapacityFactors do
  use Ecto.Migration

  @moduledoc """
  Backfills NULL `capacity_factor` rows with fuel-typical defaults.

  A NULL capacity_factor dispatches the unit at 100% of nameplate
  (`capacity_factor || 1.0` at the solver call sites) — measured at ~170 GW
  (13% of the fleet) before this fix. The defaults and the fuel-code table
  mirror `PowerModel.Ingestion.EIA.Form860` (@default_capacity_factors /
  @fuel_categories); keep the two in sync. Gas splits combined cycle
  (prime movers CC/CA/CT/CS) from simple-cycle peakers.

  Logs the generator count and MW backfilled per fuel category.
  """

  # category -> default CF (mirrors Form860.@default_capacity_factors)
  @defaults [
    {"nuclear", 0.93},
    {"coal", 0.50},
    {"gas_cc", 0.55},
    {"gas_ct", 0.12},
    {"oil", 0.10},
    {"hydro", 0.40},
    {"wind", 0.35},
    {"solar", 0.25},
    {"storage", 0.10},
    {"geothermal", 0.70},
    {"other", 0.40}
  ]

  # SQL expression mapping fuel_type/prime_mover to a default-CF category
  # (mirrors Form860.categorize_fuel/2).
  @category_sql """
  CASE
    WHEN upper(trim(fuel_type)) = 'NUC' THEN 'nuclear'
    WHEN upper(trim(fuel_type)) IN ('BIT','SUB','LIG','ANT','RC','WC','SGC') THEN 'coal'
    WHEN upper(trim(fuel_type)) IN ('NG','BFG','OG','LFG','OBG','PG')
         AND upper(trim(coalesce(prime_mover, ''))) IN ('CC','CA','CT','CS') THEN 'gas_cc'
    WHEN upper(trim(fuel_type)) IN ('NG','BFG','OG','LFG','OBG','PG') THEN 'gas_ct'
    WHEN upper(trim(fuel_type)) IN ('DFO','RFO','KER','JF','WO','PC') THEN 'oil'
    WHEN upper(trim(fuel_type)) = 'WAT' THEN 'hydro'
    WHEN upper(trim(fuel_type)) = 'WND' THEN 'wind'
    WHEN upper(trim(fuel_type)) = 'SUN' THEN 'solar'
    WHEN upper(trim(fuel_type)) = 'MWH' THEN 'storage'
    WHEN upper(trim(fuel_type)) = 'GEO' THEN 'geothermal'
    ELSE 'other'
  END
  """

  def up do
    report =
      repo().query!("""
      SELECT #{@category_sql} AS category,
             count(*)::bigint AS n,
             coalesce(sum(p_max_mw), 0)::float AS mw
      FROM generators
      WHERE capacity_factor IS NULL
      GROUP BY 1
      ORDER BY 3 DESC
      """)

    Enum.each(report.rows, fn [category, n, mw] ->
      IO.puts(
        "  capacity_factor backfill: #{category} — #{n} generators, " <>
          "#{Float.round(mw * 1.0, 1)} MW"
      )
    end)

    cf_case =
      Enum.map_join(@defaults, "\n", fn {category, cf} ->
        "WHEN '#{category}' THEN #{cf}"
      end)

    %{num_rows: updated} =
      repo().query!("""
      UPDATE generators
      SET capacity_factor = CASE (#{@category_sql})
        #{cf_case}
      END
      WHERE capacity_factor IS NULL
      """)

    IO.puts("  capacity_factor backfill: #{updated} generators updated in total")
  end

  def down do
    # Backfilled defaults are indistinguishable from measured values after
    # the fact; nothing to undo.
    :ok
  end
end
