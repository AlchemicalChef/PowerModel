defmodule Mix.Tasks.PowerModel.RestoreDb do
  @moduledoc """
  Restore the power grid database from the included dump file.

  ## Usage

      mix power_model.restore_db

  This drops and recreates the database, then restores from
  `priv/repo/power_model_dev.dump`. All grid data (buses, generators,
  transmission lines, substations, etc.) will be loaded.
  """

  use Mix.Task

  @shortdoc "Restore the database from the included dump file"

  @impl Mix.Task
  def run(_args) do
    dump_path = Path.join(:code.priv_dir(:power_model), "repo/power_model_dev.dump")

    unless File.exists?(dump_path) do
      Mix.raise("Dump file not found at #{dump_path}")
    end

    config = PowerModel.Repo.config()
    db = Keyword.fetch!(config, :database)
    username = Keyword.get(config, :username, "postgres")
    hostname = Keyword.get(config, :hostname, "localhost")

    pg_restore = System.find_executable("pg_restore") || find_homebrew_pg_restore()

    unless pg_restore do
      Mix.raise("pg_restore not found. Install PostgreSQL or add it to your PATH.")
    end

    Mix.shell().info("Dropping and recreating #{db}...")
    Mix.Task.run("ecto.drop", ["--quiet"])
    Mix.Task.run("ecto.create", ["--quiet"])

    Mix.shell().info("Restoring from #{dump_path} (38 MB)...")

    args = [
      "-U", username,
      "-h", hostname,
      "-d", db,
      "--no-owner",
      "--no-acl",
      "--clean",
      "--if-exists",
      dump_path
    ]

    case System.cmd(pg_restore, args, stderr_to_stdout: true) do
      {_output, 0} ->
        Mix.shell().info("Database restored successfully.")

      {output, code} ->
        if String.contains?(output, "WARNING") and code <= 1 do
          Mix.shell().info("Database restored (with warnings).")
        else
          Mix.shell().info("pg_restore exited with code #{code}. Output:\n#{output}")
          Mix.shell().info("Database may still be usable — check with mix phx.server")
        end
    end
  end

  defp find_homebrew_pg_restore do
    paths = [
      "/opt/homebrew/opt/postgresql@17/bin/pg_restore",
      "/opt/homebrew/opt/postgresql@16/bin/pg_restore",
      "/opt/homebrew/opt/postgresql@15/bin/pg_restore",
      "/usr/local/opt/postgresql@17/bin/pg_restore",
      "/usr/local/opt/postgresql@16/bin/pg_restore",
      "/usr/local/bin/pg_restore"
    ]

    Enum.find(paths, &File.exists?/1)
  end
end
