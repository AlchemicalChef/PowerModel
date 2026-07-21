defmodule PowerModel.Simulation.Cascading.IslandDetector do
  @moduledoc """
  Detects electrical islands in the grid using BFS on the adjacency graph.
  When branches trip, the grid can split into disconnected subnetworks.
  """

  @doc """
  Detect islands from a set of buses and in-service branches.
  Returns a list of islands, each being a MapSet of bus_ids.
  """
  def detect(bus_ids, lines, transformers) do
    adj = build_adjacency(lines, transformers)
    bus_set = MapSet.new(bus_ids)

    {islands, _visited} =
      Enum.reduce(bus_ids, {[], MapSet.new()}, fn bus_id, {islands, visited} ->
        if MapSet.member?(visited, bus_id) do
          {islands, visited}
        else
          island = bfs(bus_id, adj, bus_set)
          {[island | islands], MapSet.union(visited, island)}
        end
      end)

    Enum.reverse(islands)
  end

  @doc """
  Assign slack bus for each island (largest generator capacity).
  Returns map of island_index => slack_bus_id.
  """
  def assign_slack_buses(islands, generators) do
    gen_capacity =
      Enum.group_by(generators, & &1.bus_id)
      |> Map.new(fn {bus_id, gens} ->
        {bus_id, Enum.sum(Enum.map(gens, & &1.p_max_mw))}
      end)

    islands
    |> Enum.with_index()
    |> Enum.map(fn {island, idx} ->
      slack =
        island
        |> MapSet.to_list()
        |> Enum.max_by(fn bus_id -> Map.get(gen_capacity, bus_id, 0.0) end, fn -> nil end)

      {idx, slack}
    end)
    |> Map.new()
  end

  @doc """
  Check if an island has sufficient generation to serve its load.
  Returns {:ok, surplus_mw} or {:deficit, deficit_mw}.
  """
  def island_balance(island, generators, loads) do
    island_set = if is_struct(island, MapSet), do: island, else: MapSet.new(island)

    gen_mw =
      generators
      |> Enum.filter(&MapSet.member?(island_set, &1.bus_id))
      |> Enum.sum_by(fn g -> g.p_max_mw * (g.capacity_factor || 1.0) end)

    load_mw =
      loads
      |> Enum.filter(&MapSet.member?(island_set, &1.bus_id))
      |> Enum.sum_by(& &1.p_mw)

    balance = gen_mw - load_mw
    if balance >= 0, do: {:ok, balance}, else: {:deficit, abs(balance)}
  end

  # Private

  defp build_adjacency(lines, transformers) do
    adj = %{}

    adj =
      Enum.reduce(lines, adj, fn line, acc ->
        acc
        |> Map.update(
          line.from_bus_id,
          MapSet.new([line.to_bus_id]),
          &MapSet.put(&1, line.to_bus_id)
        )
        |> Map.update(
          line.to_bus_id,
          MapSet.new([line.from_bus_id]),
          &MapSet.put(&1, line.from_bus_id)
        )
      end)

    Enum.reduce(transformers, adj, fn xfmr, acc ->
      acc
      |> Map.update(
        xfmr.from_bus_id,
        MapSet.new([xfmr.to_bus_id]),
        &MapSet.put(&1, xfmr.to_bus_id)
      )
      |> Map.update(
        xfmr.to_bus_id,
        MapSet.new([xfmr.from_bus_id]),
        &MapSet.put(&1, xfmr.from_bus_id)
      )
    end)
  end

  defp bfs(start, adj, valid_buses) do
    bfs_loop(:queue.in(start, :queue.new()), MapSet.new([start]), adj, valid_buses)
  end

  defp bfs_loop(queue, visited, adj, valid_buses) do
    case :queue.out(queue) do
      {:empty, _} ->
        visited

      {{:value, node}, queue} ->
        neighbors = Map.get(adj, node, MapSet.new())

        {queue, visited} =
          Enum.reduce(MapSet.to_list(neighbors), {queue, visited}, fn neighbor, {q, v} ->
            if MapSet.member?(v, neighbor) or not MapSet.member?(valid_buses, neighbor) do
              {q, v}
            else
              {:queue.in(neighbor, q), MapSet.put(v, neighbor)}
            end
          end)

        bfs_loop(queue, visited, adj, valid_buses)
    end
  end
end
