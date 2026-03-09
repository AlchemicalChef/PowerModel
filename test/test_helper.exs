ExUnit.start()

# Only set up Ecto sandbox if the database is available
try do
  Ecto.Adapters.SQL.Sandbox.mode(PowerModel.Repo, :manual)
rescue
  _ -> :ok
catch
  :exit, _ -> :ok
end
