defmodule PowerModel.Failure.MonteCarlo do
  @moduledoc """
  Monte Carlo contingency screening using LODF for fast evaluation.

  Instead of solving a full DC power flow for every contingency, this module
  uses Line Outage Distribution Factors to update flows in O(branches) per
  contingency. This enables screening thousands of N-k combinations in
  seconds rather than hours.

  ## Functions

  - `screen_n2/2`          — exhaustive or sampled N-2 screening
  - `screen_random_nk/2`   — random N-k with configurable k range
  - `screen_geographic/3`  — N-1 screening under a stress scenario
  - `score_contingency/2`  — score a single set of tripped lines via LODF
  """

  alias PowerModel.Solver.LODF

  @type contingency_result :: %{
    tripped: [{:line, integer()}],
    max_loading_pct: float(),
    overloaded_count: integer(),
    mw_at_risk: float(),
    island_split: boolean(),
    score: float()
  }

  # ---------------------------------------------------------------------------
  # N-2 screening
  # ---------------------------------------------------------------------------

  @doc """
  Screen N-2 contingencies (pairs of line outages).

  For large grids, a random sample is drawn rather than exhaustive enumeration
  (the number of pairs is O(L^2) which can exceed millions).

  ## Options

    * `:sample_size` — max number of pairs to evaluate (default 10_000)
    * `:top_k`       — return the K most severe contingencies (default 20)
    * `:base_mva`    — system base MVA (default 100.0)
  """
  @spec screen_n2(map(), keyword()) :: [contingency_result()]
  def screen_n2(snapshot, opts \\ []) do
    sample_size = Keyword.get(opts, :sample_size, 10_000)
    top_k = Keyword.get(opts, :top_k, 20)

    lodf = init_lodf(snapshot, opts)
    if lodf == nil, do: throw({:error, :lodf_init_failed})

    branch_keys = active_branch_keys(lodf)
    total_pairs = div(length(branch_keys) * (length(branch_keys) - 1), 2)

    pairs =
      if total_pairs <= sample_size do
        # Exhaustive: all pairs
        for {a, i} <- Enum.with_index(branch_keys),
            {b, j} <- Enum.with_index(branch_keys),
            i < j,
            do: [a, b]
      else
        # Sampled: deterministic random pairs
        sample_pairs(branch_keys, sample_size)
      end

    pairs
    |> Enum.map(fn pair -> score_contingency(lodf, pair) end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(top_k)
  end

  # ---------------------------------------------------------------------------
  # Random N-k screening
  # ---------------------------------------------------------------------------

  @doc """
  Screen random N-k contingencies with k drawn from a configurable range.

  ## Options

    * `:k_range`     — range of k values to sample (default 2..4)
    * `:sample_size` — total number of contingencies to evaluate (default 10_000)
    * `:top_k`       — return the K most severe (default 20)
    * `:base_mva`    — system base MVA (default 100.0)
  """
  @spec screen_random_nk(map(), keyword()) :: [contingency_result()]
  def screen_random_nk(snapshot, opts \\ []) do
    k_range = Keyword.get(opts, :k_range, 2..4)
    sample_size = Keyword.get(opts, :sample_size, 10_000)
    top_k = Keyword.get(opts, :top_k, 20)

    lodf = init_lodf(snapshot, opts)
    if lodf == nil, do: throw({:error, :lodf_init_failed})

    branch_keys = active_branch_keys(lodf)
    k_values = Enum.to_list(k_range)
    samples_per_k = div(sample_size, length(k_values))

    contingencies =
      Enum.flat_map(k_values, fn k ->
        sample_combinations(branch_keys, k, samples_per_k)
      end)

    contingencies
    |> Enum.map(fn combo -> score_contingency(lodf, combo) end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(top_k)
  end

  # ---------------------------------------------------------------------------
  # Geographic screening under stress scenario
  # ---------------------------------------------------------------------------

  @doc """
  Screen N-1 contingencies under a stress scenario.

  Applies the scenario deratings to the snapshot first (modifying line
  ratings and load levels), then runs N-1 screening with LODF to find
  contingencies that are benign normally but dangerous during the event.

  ## Options

    * `:top_k`    — return the K most severe (default 20)
    * `:base_mva` — system base MVA (default 100.0)
  """
  @spec screen_geographic(map(), struct(), keyword()) :: [contingency_result()]
  def screen_geographic(snapshot, scenario, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, 20)

    # Apply scenario deratings to the snapshot (not a cascade struct,
    # so we apply manually to the snapshot maps)
    stressed_snapshot = apply_scenario_to_snapshot(snapshot, scenario)

    lodf = init_lodf(stressed_snapshot, opts)
    if lodf == nil, do: throw({:error, :lodf_init_failed})

    branch_keys = active_branch_keys(lodf)

    # N-1: trip each branch individually
    branch_keys
    |> Enum.map(fn key -> score_contingency(lodf, [key]) end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(top_k)
  end

  # ---------------------------------------------------------------------------
  # Score a single contingency
  # ---------------------------------------------------------------------------

  @doc """
  Score a single contingency (list of branch keys to trip).

  Applies LODF sequentially for each tripped branch. Returns a result map
  with overload metrics and a composite severity score.

  The composite score is:

      score = max_loading_pct * 0.4 + overloaded_count * 10.0 + mw_at_risk * 0.1
              + (if island_split, 500, 0)

  Higher scores indicate more severe contingencies.
  """
  @spec score_contingency(%LODF{}, [{:line | :transformer, integer()}]) :: contingency_result()
  def score_contingency(%LODF{} = lodf, tripped_keys) when is_list(tripped_keys) do
    {final_lodf, island_split} =
      Enum.reduce(tripped_keys, {lodf, false}, fn key, {state, split} ->
        case LODF.trip_line(state, key) do
          {:ok, new_state, _flows} -> {new_state, split}
          {:island_split, new_state} -> {new_state, true}
          {:error, new_state} -> {new_state, split}
        end
      end)

    # Evaluate post-contingency flows
    branch_map = Map.new(final_lodf.branches, fn b -> {b.key, b} end)
    tripped_set = final_lodf.cumulative_trips

    flow_results =
      final_lodf.base_flows
      |> Enum.reject(fn {key, _} -> MapSet.member?(tripped_set, key) end)
      |> Enum.map(fn {key, flow_mw} ->
        branch = Map.get(branch_map, key)
        rating = if branch, do: branch.rating, else: 0.0

        loading_pct = if rating > 0.0, do: abs(flow_mw) / rating * 100.0, else: 0.0
        overloaded = rating > 0.0 and abs(flow_mw) > rating

        {key, loading_pct, overloaded, if(overloaded, do: abs(flow_mw), else: 0.0)}
      end)

    max_loading = flow_results |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0.0 end)
    overloaded_count = Enum.count(flow_results, &elem(&1, 2))
    mw_at_risk = flow_results |> Enum.map(&elem(&1, 3)) |> Enum.sum()

    score = max_loading * 0.4 +
            overloaded_count * 10.0 +
            mw_at_risk * 0.1 +
            if(island_split, do: 500.0, else: 0.0)

    %{
      tripped: tripped_keys,
      max_loading_pct: max_loading,
      overloaded_count: overloaded_count,
      mw_at_risk: mw_at_risk,
      island_split: island_split,
      score: score
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp init_lodf(snapshot, opts) do
    base_mva = Keyword.get(opts, :base_mva, 100.0)

    try do
      alias PowerModel.Solver.DCPowerFlow
      solution = DCPowerFlow.solve(snapshot, base_mva: base_mva)
      LODF.init(snapshot, solution, base_mva: base_mva)
    rescue
      _ -> nil
    catch
      :throw, _ -> nil
    end
  end

  defp active_branch_keys(%LODF{} = lodf) do
    lodf.branches
    |> Enum.map(& &1.key)
    |> Enum.reject(fn key -> MapSet.member?(lodf.cumulative_trips, key) end)
  end

  # Sample random pairs of branch keys (deterministic via :erlang.phash2)
  defp sample_pairs(branch_keys, sample_size) do
    n = length(branch_keys)
    arr = :array.from_list(branch_keys)

    0..(sample_size - 1)
    |> Enum.map(fn seed ->
      i = rem(:erlang.phash2({:pair, seed, :a}, n * n), n)
      j = rem(:erlang.phash2({:pair, seed, :b}, n * n), n)
      # Ensure i != j
      j = if i == j, do: rem(j + 1, n), else: j
      {min(i, j), max(i, j)}
    end)
    |> Enum.uniq()
    |> Enum.map(fn {i, j} -> [:array.get(i, arr), :array.get(j, arr)] end)
  end

  # Sample random k-element combinations
  defp sample_combinations(branch_keys, k, count) do
    n = length(branch_keys)
    arr = :array.from_list(branch_keys)

    0..(count - 1)
    |> Enum.map(fn seed ->
      indices =
        0..(k - 1)
        |> Enum.map(fn slot ->
          rem(:erlang.phash2({:combo, seed, slot}, n * n * (slot + 1)), n)
        end)
        |> Enum.uniq()

      # If we got duplicates, fill in with sequential offsets
      indices = ensure_k_unique(indices, k, n)

      indices
      |> Enum.sort()
      |> Enum.map(fn i -> :array.get(i, arr) end)
    end)
    |> Enum.uniq()
  end

  defp ensure_k_unique(indices, k, _n) when length(indices) >= k, do: Enum.take(indices, k)
  defp ensure_k_unique(indices, k, n) do
    used = MapSet.new(indices)
    extras = Enum.reduce_while(0..(n - 1), {indices, used}, fn i, {acc, set} ->
      if length(acc) >= k do
        {:halt, {acc, set}}
      else
        if MapSet.member?(set, i) do
          {:cont, {acc, set}}
        else
          {:cont, {[i | acc], MapSet.put(set, i)}}
        end
      end
    end)
    elem(extras, 0) |> Enum.take(k)
  end

  # Apply a Scenarios struct to a raw snapshot (not a Cascade struct)
  defp apply_scenario_to_snapshot(snapshot, scenario) do
    updated_lines =
      Map.get(snapshot, :lines, [])
      |> Enum.reject(fn line -> line.id in scenario.forced_trips end)
      |> Enum.map(fn line ->
        case Map.get(scenario.line_deratings, line.id) do
          nil -> line
          factor ->
            rating = Map.get(line, :rating_a_mva) || 0.0
            %{line | rating_a_mva: rating * factor}
        end
      end)

    updated_loads =
      Map.get(snapshot, :loads, [])
      |> Enum.map(fn load ->
        case Map.get(scenario.load_multipliers, load.id) do
          nil -> load
          mult ->
            q = Map.get(load, :q_mvar) || 0.0
            %{load | p_mw: load.p_mw * mult, q_mvar: q * mult}
        end
      end)

    updated_gens =
      Map.get(snapshot, :generators, [])
      |> Enum.map(fn gen ->
        case Map.get(scenario.generator_deratings, gen.id) do
          nil -> gen
          factor -> %{gen | p_max_mw: gen.p_max_mw * factor}
        end
      end)

    %{snapshot |
      lines: updated_lines,
      loads: updated_loads,
      generators: updated_gens
    }
  end
end
