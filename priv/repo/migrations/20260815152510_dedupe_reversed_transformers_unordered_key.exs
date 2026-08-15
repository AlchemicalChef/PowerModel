defmodule PowerModel.Repo.Migrations.DedupeReversedTransformersUnorderedKey do
  use Ecto.Migration

  @moduledoc """
  ROADMAP item 8 (unordered-pair transformer key).

  20260815024044 deduped on the ORDERED pair `(from_bus_id, to_bus_id)`, which
  is not the identity of a transformer: a bank recreated with its terminals
  swapped (the old creation path read the rating off whichever row came first,
  so direction was not stable) passes that index and lands as a second bank
  between the same two buses. Dedupe on the unordered pair, keeping the lowest
  id, and make the index itself unordered so no future writer can reintroduce
  the reversed twin.

  Note the `LEAST/GREATEST` expression index cannot be named by column list, so
  the upsert in `BusMapper` targets it with an `{:unsafe_fragment, ...}`
  conflict target spelled exactly as the index expression.
  """

  @old_index :transformers_from_bus_id_to_bus_id_index
  @new_index :transformers_bus_pair_index

  def up do
    execute """
    DELETE FROM transformers t
    USING transformers keep
    WHERE LEAST(t.from_bus_id, t.to_bus_id) = LEAST(keep.from_bus_id, keep.to_bus_id)
      AND GREATEST(t.from_bus_id, t.to_bus_id) = GREATEST(keep.from_bus_id, keep.to_bus_id)
      AND t.id > keep.id
    """

    drop_if_exists index(:transformers, [:from_bus_id, :to_bus_id], name: @old_index)

    create unique_index(
             :transformers,
             ["LEAST(from_bus_id, to_bus_id)", "GREATEST(from_bus_id, to_bus_id)"],
             name: @new_index
           )
  end

  def down do
    drop_if_exists index(:transformers, [], name: @new_index)

    create unique_index(:transformers, [:from_bus_id, :to_bus_id], name: @old_index)
  end
end
