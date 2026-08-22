defmodule PowerModel.Ingestion.OSM.SubstationMatch do
  @moduledoc """
  One piece of OSM voltage evidence attached to a HIFLD substation.

  This table is the SEPARABLE OSM side of the ODbL architecture (ROADMAP
  item 24): every OSM-derived datum in the database is either a row here or a
  `substations` row whose `voltage_source` starts with `osm` — dropping the
  table and nulling those rows extracts OpenStreetMap entirely. `osm_type` +
  `osm_id` cite the object in the vendored snapshot
  (`data/vendored/osm_substations_*.json`, see PROVENANCE.md).

  `status` records the matcher's decision: `"applied"` rows were written into
  the yard's `voltage_levels`; `"held"` rows are evidence the matcher found
  but refused to apply (ambiguous second candidate, name veto, or
  inconsistency with incident HIFLD line voltages), kept for review.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "osm_substation_matches" do
    belongs_to :substation, PowerModel.Grid.Substation

    field :osm_type, :string
    field :osm_id, :integer
    field :osm_name, :string
    field :raw_voltage, :string
    field :levels_kv, {:array, :float}, default: []
    field :distance_m, :float
    field :name_similarity, :float
    field :match_method, :string
    field :status, :string
    field :reason, :string
    field :snapshot_date, :date

    timestamps()
  end

  def changeset(match, attrs) do
    match
    |> cast(attrs, [
      :substation_id,
      :osm_type,
      :osm_id,
      :osm_name,
      :raw_voltage,
      :levels_kv,
      :distance_m,
      :name_similarity,
      :match_method,
      :status,
      :reason,
      :snapshot_date
    ])
    |> validate_required([:substation_id, :osm_type, :osm_id, :match_method, :status])
    |> validate_inclusion(:osm_type, ["node", "way", "relation"])
    |> validate_inclusion(:match_method, ["distance", "distance+name", "line_inferred"])
    |> validate_inclusion(:status, ["applied", "held"])
    |> unique_constraint([:substation_id, :osm_type, :osm_id])
  end
end
