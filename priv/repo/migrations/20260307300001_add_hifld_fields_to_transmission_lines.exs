defmodule PowerModel.Repo.Migrations.AddHifldFieldsToTransmissionLines do
  use Ecto.Migration

  def change do
    alter table(:transmission_lines) do
      # "AC; OVERHEAD", "AC; UNDERGROUND", "DC; OVERHEAD"
      add :line_type, :string
      add :owner, :string
      # HIFLD substation 1 name/ID
      add :sub_1, :string
      # HIFLD substation 2 name/ID
      add :sub_2, :string
      add :naics_code, :string
      add :naics_desc, :string
    end

    create index(:transmission_lines, [:sub_1])
    create index(:transmission_lines, [:sub_2])
    create index(:transmission_lines, [:owner])
  end
end
