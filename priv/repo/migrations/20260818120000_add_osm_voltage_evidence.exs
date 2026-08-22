defmodule PowerModel.Repo.Migrations.AddOsmVoltageEvidence do
  use Ecto.Migration

  @moduledoc """
  ROADMAP item 24 (OSM voltage backfill), licensing architecture per the ODbL
  notes there: the OSM evidence lives in its own SEPARABLE table
  (`osm_substation_matches`), and the applied values on `substations` carry a
  `voltage_source` marker so the OSM-derived subset is extractable at any time.
  Dropping the table and nulling the marked rows removes every OSM-derived
  datum; the HIFLD side stays a clean collective-database component.

  `substations.voltage_source` values: NULL (native HIFLD / line-augmented
  pipeline voltage), `osm_matched` (yard matched to a voltage-tagged OSM
  substation), `osm_line_inferred` (voltage lent by OSM power lines passing
  the yard). `Substations.augment_voltage_levels_from_lines/0` skips `osm%`
  rows so a later augmentation re-run cannot overwrite OSM-sourced levels
  with the circular restored-circuit echoes it would otherwise lend back.

  `transmission_lines.voltage_source` values: NULL (HIFLD-carried or
  yard-inferred voltage), `osm_corridor` (class corrected from OSM corridor
  way evidence), `osm_rederived` (TOPO-1 restored circuit re-derived from
  OSM-backed yard levels). Same extractability requirement as the yards: the
  OSM-derived subset of line voltages must be enumerable in-DB.
  """

  def change do
    alter table(:substations) do
      add :voltage_source, :string
    end

    create index(:substations, [:voltage_source])

    alter table(:transmission_lines) do
      add :voltage_source, :string
    end

    create index(:transmission_lines, [:voltage_source])

    create table(:osm_substation_matches) do
      add :substation_id, references(:substations, on_delete: :delete_all), null: false
      # "node" | "way" | "relation" + the OSM object id: the citation back into
      # the vendored snapshot (and into OSM itself).
      add :osm_type, :string, null: false
      add :osm_id, :bigint, null: false
      add :osm_name, :string
      # The voltage tag exactly as OSM carries it (volts, semicolon-joined).
      add :raw_voltage, :string
      # Parsed yard levels in kV: volts -> kV, deduped within 5%, < 20 kV
      # distribution/traction levels dropped.
      add :levels_kv, {:array, :float}, null: false, default: []
      add :distance_m, :float
      add :name_similarity, :float
      # "distance" | "distance+name" | "line_inferred"
      add :match_method, :string, null: false
      # "applied" (written into substations.voltage_levels) | "held" (evidence
      # recorded but not applied — ambiguous or inconsistent).
      add :status, :string, null: false
      add :reason, :string
      add :snapshot_date, :date

      timestamps()
    end

    create unique_index(:osm_substation_matches, [:substation_id, :osm_type, :osm_id])
    create index(:osm_substation_matches, [:status])
  end
end
