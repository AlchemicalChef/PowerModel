defmodule PowerModel.Repo.Migrations.AddGeneratorIdentity do
  use Ecto.Migration

  @moduledoc """
  Gives generators a natural key.

  Before this migration generators had no unique constraint at all, so every
  re-run of the EIA-860 ingest doubled the fleet. This migration:

  1. Deduplicates existing rows. Duplicates from prior re-ingests are exact
     copies of every ingested attribute, so rows are grouped by
     (eia_plant_id, fuel_type, prime_mover, p_max_mw, p_min_mw, status) and
     only the best row per group survives — preferring rows already enriched
     by later pipeline stages (mapped bus_id, measured capacity_factor),
     then the lowest id. NOTE: genuine twin units (two identical units at
     one plant) are indistinguishable from re-ingest duplicates without a
     generator id and are collapsed too; they are restored as distinct rows
     by the next EIA-860 ingest, which captures the EIA Generator ID.

  2. Adds the `generator_id` column (EIA-860 "Generator ID").

  3. Adds a partial unique index on (eia_plant_id, generator_id) — partial
     because pre-existing rows and non-standard files have no generator_id.
     The ingest upserts against exactly this index (see
     `PowerModel.Ingestion.EIA.Form860.insert_generator/1`).
  """

  def up do
    %{num_rows: deduped} =
      repo().query!("""
      DELETE FROM generators g USING (
        SELECT id,
               row_number() OVER (
                 PARTITION BY eia_plant_id, fuel_type, prime_mover,
                              p_max_mw, p_min_mw, status
                 ORDER BY (bus_id IS NULL), (capacity_factor IS NULL), id
               ) AS rn
        FROM generators
        WHERE eia_plant_id IS NOT NULL
      ) dup
      WHERE g.id = dup.id AND dup.rn > 1
      """)

    IO.puts("  generators deduplicated (re-ingest copies removed): #{deduped}")

    alter table(:generators) do
      add :generator_id, :string
    end

    create unique_index(:generators, [:eia_plant_id, :generator_id],
             where: "eia_plant_id IS NOT NULL AND generator_id IS NOT NULL"
           )
  end

  def down do
    drop unique_index(:generators, [:eia_plant_id, :generator_id],
           where: "eia_plant_id IS NOT NULL AND generator_id IS NOT NULL"
         )

    alter table(:generators) do
      remove :generator_id
    end

    # Deduplicated rows are not restorable.
  end
end
