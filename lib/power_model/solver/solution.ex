defmodule PowerModel.Solver.Solution do
  @moduledoc """
  Represents the result of a power flow solution.
  """

  defstruct [
    :bus_ids,
    :vm_pu,
    :va_rad,
    :line_flows,
    :base_mva,
    :converged,
    :iterations,
    :max_mismatch,
    :total_gen_mw,
    :total_load_mw,
    :total_loss_mw,
    :scheduled_gen_mw,
    :slack_bus_id,
    :slack_injection_mw,
    :mismatch_mw,
    :mismatch_abs_mw,
    # Number of islands whose solutions were merged into this one. A direct
    # (single-island) solve is 1; an empty merge (nothing solvable) is 0.
    :n_islands_solved,
    # Load and bus count in dead (unsolvable, blacked-out) islands that were
    # excluded from the solve. Populated by `solve_islands` from the Partition
    # dead set so callers can account for unserved load.
    :dead_load_mw,
    :dead_bus_count
  ]

  def new(bus_ids, vm_pu, va_rad, line_flows, base_mva, extra \\ []) do
    struct!(
      %__MODULE__{
        bus_ids: bus_ids,
        vm_pu: vm_pu,
        va_rad: va_rad,
        line_flows: line_flows,
        base_mva: base_mva,
        converged: true,
        iterations: 1,
        max_mismatch: 0.0,
        total_gen_mw: 0.0,
        total_load_mw: 0.0,
        total_loss_mw: 0.0,
        scheduled_gen_mw: 0.0,
        slack_bus_id: nil,
        slack_injection_mw: 0.0,
        mismatch_mw: nil,
        mismatch_abs_mw: nil,
        n_islands_solved: 1,
        dead_load_mw: 0.0,
        dead_bus_count: 0
      },
      extra
    )
  end

  @doc """
  Aggregate overload statistics across all branch flows.

  A branch is *monitored* when its `rating_mva` is a positive number; branches
  without a usable rating are counted in `unrated_count` so they cannot
  silently pass as healthy.
  """
  def overload_summary(%__MODULE__{line_flows: flows}) do
    Enum.reduce(
      flows,
      %{
        overloaded_count: 0,
        max_loading_pct: 0.0,
        overload_mw: 0.0,
        monitored_count: 0,
        unrated_count: 0
      },
      fn {_key, flow}, acc ->
        rating = Map.get(flow, :rating_mva)

        if is_number(rating) and rating > 0 do
          mag = flow_magnitude(flow)
          loading = Map.get(flow, :loading_pct, 0.0)

          acc = %{
            acc
            | monitored_count: acc.monitored_count + 1,
              max_loading_pct: max(acc.max_loading_pct, loading)
          }

          if Map.get(flow, :overloaded, false) do
            %{
              acc
              | overloaded_count: acc.overloaded_count + 1,
                overload_mw: acc.overload_mw + max(mag - rating, 0.0)
            }
          else
            acc
          end
        else
          %{acc | unrated_count: acc.unrated_count + 1}
        end
      end
    )
  end

  @doc """
  Check the power-balance invariant: generation − load − losses ≈ 0.

  The internal identity alone is tautological for any genuine solve (DC sets
  gen = load by construction; converged AC defines gen = load + loss), so an
  optional `expected_load_mw` — the snapshot's demand — can be supplied as a
  third argument. When given, the served load plus the dead-island load
  (`total_load_mw + dead_load_mw`) must also match it within tolerance,
  which catches load that silently vanished from the solve.
  """
  def energy_balance(%__MODULE__{} = s, tol_mw \\ 1.0, expected_load_mw \\ nil) do
    residual = (s.total_gen_mw || 0.0) - (s.total_load_mw || 0.0) - (s.total_loss_mw || 0.0)
    internal_ok = abs(residual) <= tol_mw

    case expected_load_mw do
      nil ->
        %{residual_mw: residual, ok: internal_ok}

      expected when is_number(expected) ->
        accounted = (s.total_load_mw || 0.0) + (s.dead_load_mw || 0.0)
        load_residual = accounted - expected

        %{
          residual_mw: residual,
          load_residual_mw: load_residual,
          expected_load_mw: expected,
          accounted_load_mw: accounted,
          ok: internal_ok and abs(load_residual) <= tol_mw
        }
    end
  end

  defp flow_magnitude(flow) do
    case Map.get(flow, :s_flow_mva) do
      s when is_number(s) -> abs(s)
      _ -> abs(Map.get(flow, :p_flow_mw, 0.0))
    end
  end

  def overloaded_lines(%__MODULE__{line_flows: flows}) do
    flows
    |> Enum.filter(fn {_key, flow} -> flow.overloaded end)
    |> Map.new()
  end

  def voltage_violations(%__MODULE__{bus_ids: ids, vm_pu: vm}, opts \\ []) do
    low = Keyword.get(opts, :low, 0.9)
    high = Keyword.get(opts, :high, 1.1)

    Enum.zip(ids, vm)
    |> Enum.filter(fn {_id, v} -> v < low or v > high end)
    |> Map.new()
  end

  def bus_voltage(%__MODULE__{bus_ids: ids, vm_pu: vm, va_rad: va}, bus_id) do
    case Enum.find_index(ids, &(&1 == bus_id)) do
      nil -> nil
      idx -> %{vm_pu: Enum.at(vm, idx, 1.0), va_rad: Enum.at(va, idx, 0.0)}
    end
  end

  def line_flow(%__MODULE__{line_flows: flows}, type, id) do
    Map.get(flows, {type, id})
  end
end
