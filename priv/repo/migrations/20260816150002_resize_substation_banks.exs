defmodule PowerModel.Repo.Migrations.ResizeSubstationBanks do
  use Ecto.Migration

  @moduledoc """
  Sizes substation banks to the load their low side actually carries
  (TOPO-6).

  69 of the network's big radial buses are the low side of a two-level yard
  behind one bank rated off nothing but its high-side voltage class — a
  200 MVA estimate serving 721 MW at Houston RITTENHOUSE, 401 MW at SAINT
  HEDWIG. A real distribution substation carrying 400 MW has several banks;
  the model had one, and every N-1 on it is a total-loss island that the real
  yard would ride through.

  This is a DATA migration: it calls
  `BusMapper.resize_transformers_to_through_load/0`, the same pass
  `Cleanup.run/0` now runs once the loads exist. The rating goes up in whole
  multiples of the class's standard unit until the low side sits at or below
  80% of it, and the LIN-3 rebase then gives that row the reactance of that
  many standard banks in parallel — which is what the yard has. Only banks
  joining two SUBSTATION buses are touched, so MATPOWER nameplates are
  untouched, and the rating is a pure function of the current low-side load,
  so a second run is a no-op and a later load reallocation takes the rating
  back down with it.
  """

  def up do
    summary = PowerModel.Ingestion.BusMapper.resize_transformers_to_through_load()

    IO.puts(
      "Substation banks re-rated to their low-side load: #{summary.resized} " <>
        "(+#{Float.round(summary.added_mva, 1)} MVA)"
    )
  end

  def down do
    # No reverse: the pre-migration rating was a function of the high-side
    # voltage class alone, and re-deriving it here would duplicate
    # estimate_transformer_rating/1 in a file that cannot see it. Re-running
    # `mix power_model.ingest map_buses` rebuilds every bank from the recipe.
    :ok
  end
end
