defmodule PowerModel.Grid.Transformer do
  use Ecto.Schema
  import Ecto.Changeset

  schema "transformers" do
    field :rated_mva, :float
    field :r_pu, :float
    field :x_pu, :float
    field :tap_ratio, :float, default: 1.0
    field :status, :string, default: "in_service"
    # Stamp of the parameter recipe that wrote rated_mva/r_pu/x_pu. A re-map
    # pass revisits every row below `BusMapper.params_version/0` instead of
    # only filling NULLs, so a corrected recipe can reach existing rows.
    field :params_version, :integer, default: 0
    # Parallel circuits inferred from at-rest loading (CapacityInference).
    # The factor is folded into r/x/b and the ratings; 1 means none inferred.
    field :inferred_circuits, :integer, default: 1

    belongs_to :from_bus, PowerModel.Grid.Bus
    belongs_to :to_bus, PowerModel.Grid.Bus

    timestamps()
  end

  def changeset(transformer, attrs) do
    transformer
    |> cast(attrs, [
      :rated_mva,
      :r_pu,
      :x_pu,
      :tap_ratio,
      :status,
      :params_version,
      :from_bus_id,
      :to_bus_id
    ])
    |> validate_required([:rated_mva, :x_pu, :from_bus_id, :to_bus_id])
    |> validate_number(:tap_ratio, greater_than: 0.0)
    |> foreign_key_constraint(:from_bus_id)
    |> foreign_key_constraint(:to_bus_id)
  end
end
