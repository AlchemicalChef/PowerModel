defmodule PowerModel.Solver.Partition do
  @moduledoc """
  Partition a grid snapshot into electrically separate islands and merge
  per-island power-flow solutions.

  The US grid is three asynchronous AC systems (Eastern, Western, ERCOT)
  joined only by DC ties; a snapshot containing several interconnections is
  NOT one electrical network. Solving it as one system couples flows and
  dispatch across boundaries that physics keeps separate. Every snapshot-level
  solve must therefore partition first and solve each island independently.
  """

  alias PowerModel.Simulation.Cascading.IslandDetector
  alias PowerModel.Solver.Solution

  @doc """
  Split a snapshot into per-island sub-snapshots (only islands that are
  solvable: at least `min_buses` buses and at least one generator).
  Returns `{solvable_subsnapshots, dead_island_bus_sets}`.

  Single-bus islands with generation are trivially solvable (θ = 0), so the
  default `min_buses` is 1; islands without any generator are dead
  (blacked out) regardless of size.
  """
  def split(snapshot, min_buses \\ 1) do
    bus_ids = Enum.map(snapshot.buses, & &1.id)
    islands = IslandDetector.detect(bus_ids, snapshot.lines, snapshot.transformers)

    gen_buses = MapSet.new(snapshot.generators, & &1.bus_id)

    {solvable, dead} =
      Enum.split_with(islands, fn island ->
        MapSet.size(island) >= min_buses and
          Enum.any?(island, &MapSet.member?(gen_buses, &1))
      end)

    subs =
      Enum.map(solvable, fn island ->
        %{
          buses: Enum.filter(snapshot.buses, &MapSet.member?(island, &1.id)),
          lines:
            Enum.filter(snapshot.lines, fn l ->
              MapSet.member?(island, l.from_bus_id) and MapSet.member?(island, l.to_bus_id)
            end),
          transformers:
            Enum.filter(snapshot.transformers, fn t ->
              MapSet.member?(island, t.from_bus_id) and MapSet.member?(island, t.to_bus_id)
            end),
          generators: Enum.filter(snapshot.generators, &MapSet.member?(island, &1.bus_id)),
          loads: Enum.filter(snapshot.loads, &MapSet.member?(island, &1.bus_id))
        }
      end)

    {subs, dead}
  end

  @doc """
  Merge per-island solutions into one `Solution` covering the whole snapshot.

  Totals sum across islands; `converged` is true only when every island
  converged; flows are the union (branch keys are disjoint across islands).
  `slack_bus_id` is taken from the largest island.

  Merging zero solutions (nothing was solvable — e.g. a total blackout) is
  NOT a converged solve: it yields `converged: false` with
  `n_islands_solved: 0` so callers cannot mistake it for a healthy grid.
  """
  def merge_solutions([], base_mva) do
    Solution.new([], [], [], %{}, base_mva,
      converged: false,
      iterations: 0,
      n_islands_solved: 0
    )
  end

  def merge_solutions(solutions, base_mva) do
    largest = Enum.max_by(solutions, &length(&1.bus_ids))
    mismatch_values = Enum.map(solutions, & &1.mismatch_mw)

    {mismatch_mw, mismatch_abs_mw} =
      if Enum.any?(mismatch_values, &is_nil/1) do
        {nil, nil}
      else
        {Enum.sum(mismatch_values), Enum.sum(Enum.map(mismatch_values, &abs/1))}
      end

    %Solution{
      bus_ids: Enum.flat_map(solutions, & &1.bus_ids),
      vm_pu: Enum.flat_map(solutions, & &1.vm_pu),
      va_rad: Enum.flat_map(solutions, & &1.va_rad),
      line_flows: Enum.reduce(solutions, %{}, &Map.merge(&2, &1.line_flows)),
      base_mva: base_mva,
      converged: Enum.all?(solutions, & &1.converged),
      iterations: solutions |> Enum.map(& &1.iterations) |> Enum.max(),
      max_mismatch: solutions |> Enum.map(&numeric(&1.max_mismatch)) |> Enum.max(),
      total_gen_mw: sum_field(solutions, :total_gen_mw),
      total_load_mw: sum_field(solutions, :total_load_mw),
      total_loss_mw: sum_field(solutions, :total_loss_mw),
      scheduled_gen_mw: sum_field(solutions, :scheduled_gen_mw),
      slack_bus_id: largest.slack_bus_id,
      slack_injection_mw: sum_field(solutions, :slack_injection_mw),
      mismatch_mw: mismatch_mw,
      mismatch_abs_mw: mismatch_abs_mw,
      n_islands_solved: length(solutions),
      dead_load_mw: sum_field(solutions, :dead_load_mw),
      dead_bus_count: Enum.reduce(solutions, 0, fn s, acc -> acc + (s.dead_bus_count || 0) end)
    }
  end

  defp sum_field(solutions, field) do
    Enum.reduce(solutions, 0.0, fn s, acc -> acc + (Map.get(s, field) || 0.0) end)
  end

  defp numeric(:infinity), do: 1.0e30
  defp numeric(v) when is_number(v), do: v
  defp numeric(_), do: 0.0
end
