defmodule PowerModel.Grid.TransmissionLine do
  use Ecto.Schema
  import Ecto.Changeset

  schema "transmission_lines" do
    field :voltage_kv, :float
    field :r_pu, :float
    field :x_pu, :float
    field :b_pu, :float
    field :rating_a_mva, :float
    # Emergency ratings (ROADMAP item 9). Rate A is the normal/continuous
    # rating and stays the display and "stressed" basis; rate B is the 4-hour
    # and rate C the short-time emergency rating. Relay pickup is rate C —
    # see `PowerModel.Failure.Cascade.trip_loading_pct/1`.
    field :rating_b_mva, :float
    field :rating_c_mva, :float
    field :length_km, :float
    # Version of the parameter estimator that last wrote r/x/b and the ratings.
    # `PowerModel.Ingestion.ParameterEstimator` recomputes rows below its own
    # version, so improved parameter tables reach existing rows (REVIEW DAT-18).
    field :params_version, :integer, default: 0
    field :geometry, Geo.PostGIS.Geometry
    field :status, :string, default: "in_service"
    field :source, :string
    field :source_id, :string
    # Where a non-HIFLD voltage class came from: nil for HIFLD-carried or
    # yard-inferred values, "osm_corridor" (corridor-way evidence) or
    # "osm_rederived" (restored circuit re-derived from OSM-backed yards).
    # Keeps the OSM-derived subset extractable under ODbL, like the same
    # column on substations.
    field :voltage_source, :string
    field :line_type, :string
    field :owner, :string
    field :sub_1, :string
    field :sub_2, :string
    field :naics_code, :string
    field :naics_desc, :string

    belongs_to :from_bus, PowerModel.Grid.Bus
    belongs_to :to_bus, PowerModel.Grid.Bus

    timestamps()
  end

  @cast_fields [
    :voltage_kv,
    :r_pu,
    :x_pu,
    :b_pu,
    :rating_a_mva,
    :rating_b_mva,
    :rating_c_mva,
    :length_km,
    :params_version,
    :geometry,
    :status,
    :source,
    :source_id,
    :voltage_source,
    :from_bus_id,
    :to_bus_id,
    :line_type,
    :owner,
    :sub_1,
    :sub_2,
    :naics_code,
    :naics_desc
  ]

  def changeset(line, attrs) do
    line
    |> cast(attrs, @cast_fields)
    |> validate_required([:voltage_kv])
    |> validate_number(:r_pu, greater_than_or_equal_to: 0)
    |> validate_number(:x_pu, greater_than: 0)
    |> unique_constraint([:source, :source_id])
    |> foreign_key_constraint(:from_bus_id)
    |> foreign_key_constraint(:to_bus_id)
  end
end
