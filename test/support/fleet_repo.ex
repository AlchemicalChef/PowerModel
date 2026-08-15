defmodule PowerModel.FleetRepo do
  @moduledoc """
  A read-only Ecto repo pointed at the DEVELOPMENT database.

  The test database is a sandbox that every test builds from scratch, which is
  what you want for unit tests and useless for the one measurement that has to
  run against the whole ingested country: the interconnection frequency-
  response validation in
  `test/power_model/solver/frequency_beta_test.exs`.

  So that test — and only that test — reads the real fleet through this repo.
  It never writes. `connect/0` returns `:error` instead of raising when the
  development database is absent, so the suite degrades to "skipped" on a
  machine that has never run an ingest rather than failing.

  Override the database with `FLEET_DB` (default `power_model_dev`).
  """

  use Ecto.Repo, otp_app: :power_model, adapter: Ecto.Adapters.Postgres

  @doc """
  Start the repo if it is not already running and the database answers.

  Returns `:ok` when queries can be issued, `{:error, reason}` otherwise.
  """
  def connect do
    config =
      Application.get_env(:power_model, PowerModel.Repo, [])
      |> Keyword.drop([:pool, :pool_size, :ownership_timeout])
      |> Keyword.merge(
        database: System.get_env("FLEET_DB", "power_model_dev"),
        pool_size: 2,
        log: false
      )

    case start_link(config) do
      {:ok, _pid} -> probe()
      {:error, {:already_started, _pid}} -> probe()
      {:error, reason} -> {:error, reason}
    end
  end

  defp probe do
    query!("SELECT 1", [])
    :ok
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end
end
