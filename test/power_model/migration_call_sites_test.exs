defmodule PowerModel.MigrationCallSitesTest do
  @moduledoc """
  Data migrations call application functions by name, and a rename in `lib`
  cannot break them at compile time — a migration is only compiled when it runs.

  Caught in review 2026-08-23: `synthesize_line_end_reactors/0` was renamed to
  `synthesize_bus_shunts/1` and migration 20260816120001 kept calling the old
  name, so `mix ecto.migrate` raised `UndefinedFunctionError` on every fresh
  checkout. Nine migrations in this repo call into `lib`; this test is the
  compile-time signal they otherwise lack.
  """
  use ExUnit.Case, async: true

  @migrations Path.wildcard("priv/repo/migrations/*.exs")

  test "every PowerModel function a migration calls still exists" do
    assert @migrations != [], "no migrations found — has the path moved?"

    missing =
      for path <- @migrations,
          {module, fun, arity} <- calls_in(File.read!(path)),
          not exported?(module, fun, arity) do
        "#{Path.basename(path)} calls #{inspect(module)}.#{fun}/#{arity}"
      end

    assert missing == [],
           "migration(s) call functions that no longer exist:\n  " <> Enum.join(missing, "\n  ")
  end

  # Fully-qualified calls only: `PowerModel.A.B.fun(args)`. Aliased or
  # dynamically-dispatched calls are out of scope, which is stated rather than
  # silently implied — this catches the rename class, not every call.
  defp calls_in(source) do
    ~r/\b(PowerModel(?:\.[A-Z][A-Za-z0-9_]*)+)\.([a-z_][A-Za-z0-9_?!]*)\(([^()]*)\)/
    |> Regex.scan(source)
    |> Enum.map(fn [_all, mod, fun, args] ->
      {Module.concat([mod]), String.to_atom(fun), arity_of(args)}
    end)
    |> Enum.uniq()
  end

  defp arity_of(args) do
    case String.trim(args) do
      "" -> 0
      trimmed -> trimmed |> String.split(",") |> length()
    end
  end

  # A function with defaults exports several arities, so accept any arity the
  # module publishes under that name at or above the call's — a call with fewer
  # arguments than the largest arity is a defaulted call, not a missing one.
  defp exported?(module, fun, arity) do
    Code.ensure_loaded?(module) and
      module.__info__(:functions)
      |> Enum.any?(fn {f, a} -> f == fun and a >= arity end)
  end
end
