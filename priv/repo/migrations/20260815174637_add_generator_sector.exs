defmodule PowerModel.Repo.Migrations.AddGeneratorSector do
  use Ecto.Migration

  @moduledoc """
  Adds the EIA-860 sector to generators (ROADMAP item 29).

  EIA-860 Schedule 3.1 carries a `Sector Name` column that the ingest parsed
  and dropped. It separates grid-scale plant (Electric Utility, IPP) from
  generation sited at a commercial or industrial host (Commercial/Industrial
  CHP and Non-CHP), and that distinction is load-bearing for dispatch:
  EIA-930's per-fuel solar and wind columns report UTILITY-SCALE generation
  only, so allocating them across onsite units too places measured MW on
  machines the measurement never counted.

  `sector` stores the raw EIA string so the seven published values survive
  intact; `utility_scale` is the derived boolean consumers read.

  Both columns are nullable. `utility_scale` NULL means "not derived from
  EIA-860" — MATPOWER imports, import pseudo-generators, and hand-built rows
  never see this ingest — and every consumer treats NULL as utility-scale,
  which is what EIA-860 is overwhelmingly made of (25.5k of 26.9k units).
  """

  def change do
    alter table(:generators) do
      add :sector, :string
      add :utility_scale, :boolean
    end
  end
end
