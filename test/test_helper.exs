# Detect whether the test database is reachable. DB-backed tests are tagged
# `:db`; they run when the database is available and are excluded otherwise
# (the rest of the suite is pure in-memory and needs no database).
db_available? =
  try do
    Ecto.Adapters.SQL.Sandbox.mode(PowerModel.Repo, :manual)
    true
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

Application.put_env(:power_model, :skip_repo, not db_available?)

ExUnit.start(exclude: if(db_available?, do: [], else: [:db]))
