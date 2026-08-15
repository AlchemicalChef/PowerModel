defmodule PowerModel.Repo.Migrations.CreateBtmSolar do
  use Ecto.Migration

  @moduledoc """
  Behind-the-meter (distributed) solar PV capacity landed on network buses.

  One row per (bus, sector). EIA-861 reports capacity by utility x state x
  sector; the ingest allocates each utility's capacity across its service
  territory and sums every utility's contribution onto the bus, so
  `capacity_mw` is a total and `utility_id` records only the largest
  contributing utility (provenance, not a foreign key — EIA utility numbers
  have no table here).

  `bus_id` nilifies rather than cascades: a bus disappearing in a re-ingest
  leaves the capacity row as evidence that BTM capacity was stranded, which
  the coverage report counts, instead of silently deleting it.
  """

  def change do
    create table(:btm_solar) do
      add :bus_id, references(:buses, on_delete: :nilify_all)
      add :sector, :string, null: false
      add :capacity_mw, :float, null: false
      add :state, :string
      add :utility_id, :string

      timestamps()
    end

    create unique_index(:btm_solar, [:bus_id, :sector])
    create index(:btm_solar, [:state])
  end
end
