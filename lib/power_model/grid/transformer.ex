defmodule PowerModel.Grid.Transformer do
  use Ecto.Schema
  import Ecto.Changeset

  schema "transformers" do
    field :rated_mva, :float
    field :r_pu, :float
    field :x_pu, :float
    field :tap_ratio, :float, default: 1.0
    field :status, :string, default: "in_service"

    belongs_to :from_bus, PowerModel.Grid.Bus
    belongs_to :to_bus, PowerModel.Grid.Bus

    timestamps()
  end

  def changeset(transformer, attrs) do
    transformer
    |> cast(attrs, [:rated_mva, :r_pu, :x_pu, :tap_ratio, :status,
                     :from_bus_id, :to_bus_id])
    |> validate_required([:rated_mva, :x_pu, :from_bus_id, :to_bus_id])
    |> foreign_key_constraint(:from_bus_id)
    |> foreign_key_constraint(:to_bus_id)
  end
end
