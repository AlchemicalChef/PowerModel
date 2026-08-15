defmodule PowerModel.Repo.Migrations.CreateDcTies do
  use Ecto.Migration

  # ROADMAP item 13: HVDC links modeled as a pair of scheduled injections
  # rather than as AC branches. `Grid.in_service_lines/1` already excludes
  # `line_type == "dc"` from every AC snapshot (REVIEW LIN-6); this table is
  # the replacement for what that exclusion removed.
  #
  # `to_bus_id` is nullable on purpose: for a tie whose far terminal sits
  # outside the modeled network (a converter in Canada, or the SPP side of an
  # ERCOT tie in an ERCOT-only snapshot) only the near end carries an
  # injection.
  def change do
    create table(:dc_ties) do
      add :name, :string, null: false
      add :from_bus_id, references(:buses, on_delete: :nilify_all)
      add :to_bus_id, references(:buses, on_delete: :nilify_all)
      # Scheduled injection AT from_bus, in MW. See PowerModel.Grid.DcTie for
      # the full sign convention.
      add :schedule_mw, :float, null: false, default: 0.0
      # Documented converter capacity. Informational: nothing trips on it yet.
      add :rating_mva, :float
      add :status, :string, default: "in_service"
      add :source, :string
      add :source_id, :string

      timestamps()
    end

    create unique_index(:dc_ties, [:source, :source_id])
    create index(:dc_ties, [:from_bus_id])
    create index(:dc_ties, [:to_bus_id])
  end
end
