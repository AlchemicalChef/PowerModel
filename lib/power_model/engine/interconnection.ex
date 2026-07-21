defmodule PowerModel.Engine.Interconnection do
  @moduledoc """
  Manages parallel solving across the 3 US interconnections.
  Eastern, Western, and ERCOT are electrically independent and can be
  solved concurrently via Task.async_stream.
  DC ties between interconnections are modeled as fixed injections.
  """

  alias PowerModel.Grid
  alias PowerModel.Solver.{DCPowerFlow, NewtonRaphson}

  @doc """
  Solve all interconnections in parallel using DC power flow.
  Returns a map of interconnection_id => solution.
  """
  def solve_all_dc(opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)

    Grid.list_interconnections()
    |> Task.async_stream(
      fn interconnection ->
        snapshot = Grid.get_grid_snapshot(interconnection.id)

        if length(snapshot.buses) > 0 do
          try do
            solution = DCPowerFlow.solve(snapshot, base_mva: base_mva)
            {interconnection.id, {:ok, solution}}
          catch
            _ -> {interconnection.id, {:error, :solve_failed}}
          end
        else
          {interconnection.id, {:error, :empty}}
        end
      end,
      max_concurrency: 3,
      timeout: 30_000
    )
    |> Enum.reduce(%{}, fn
      {:ok, {id, result}}, acc -> Map.put(acc, id, result)
      _, acc -> acc
    end)
  end

  @doc """
  Solve all interconnections in parallel using AC Newton-Raphson.
  Optionally warm-starts from DC solutions.
  """
  def solve_all_ac(dc_solutions \\ %{}, opts \\ []) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)

    Grid.list_interconnections()
    |> Task.async_stream(
      fn interconnection ->
        snapshot = Grid.get_grid_snapshot(interconnection.id)

        if length(snapshot.buses) > 0 do
          warm_start =
            case Map.get(dc_solutions, interconnection.id) do
              {:ok, sol} -> sol
              _ -> nil
            end

          case NewtonRaphson.solve(snapshot,
                 base_mva: base_mva,
                 warm_start: warm_start
               ) do
            {:ok, solution} -> {interconnection.id, {:ok, solution}}
            error -> {interconnection.id, error}
          end
        else
          {interconnection.id, {:error, :empty}}
        end
      end,
      max_concurrency: 3,
      timeout: 60_000
    )
    |> Enum.reduce(%{}, fn
      {:ok, {id, result}}, acc -> Map.put(acc, id, result)
      _, acc -> acc
    end)
  end

  @doc """
  Get summary statistics for each interconnection.
  """
  def interconnection_stats do
    Grid.list_interconnections()
    |> Enum.map(fn ic ->
      bus_count = Grid.count_buses(ic.id)
      gen_capacity = Grid.total_generation_capacity(ic.id)
      load = Grid.total_load(ic.id)

      %{
        id: ic.id,
        name: ic.name,
        bus_count: bus_count,
        gen_capacity_mw: gen_capacity,
        total_load_mw: load[:p_mw] || 0.0,
        total_load_mvar: load[:q_mvar] || 0.0
      }
    end)
  end
end
