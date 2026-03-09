defmodule PowerModel.Solver.VoltageStability do
  @moduledoc """
  Voltage stability assessment tools.

  Analyzes power flow solutions for voltage collapse risk.  Works with both
  the `%PowerModel.Solver.Solution{}` struct (lists of bus_ids and vm_pu) and
  plain maps that carry a `:bus_results` map of bus_id => %{vm_pu: ...}.
  """

  alias PowerModel.Solver.Solution

  defp bus_voltage_pairs(%Solution{bus_ids: ids, vm_pu: vm})
       when is_list(ids) and is_list(vm) do
    Enum.zip(ids, vm)
  end

  defp bus_voltage_pairs(%{bus_results: bus_results}) when is_map(bus_results) do
    Enum.map(bus_results, fn {bus_id, result} ->
      {bus_id, Map.get(result, :vm_pu) || 1.0}
    end)
  end

  defp bus_voltage_pairs(_), do: []

  defp bus_vm(%Solution{bus_ids: ids, vm_pu: vm}, bus_id) do
    case Enum.find_index(ids, &(&1 == bus_id)) do
      nil -> nil
      idx -> Enum.at(vm, idx, 1.0)
    end
  end

  defp bus_vm(%{bus_results: bus_results}, bus_id) when is_map(bus_results) do
    case Map.get(bus_results, bus_id) do
      nil -> nil
      result -> Map.get(result, :vm_pu) || 1.0
    end
  end

  defp bus_vm(_, _bus_id), do: nil

  @doc """
  Check a power flow solution for voltage violations.

  Returns a list of `%{bus_id, vm_pu, status}` for every bus whose voltage
  falls outside the normal band.  Status values:

    * `:normal`   -- 0.95 <= V <= 1.05
    * `:warning`  -- 0.90 <= V < 0.95 or 1.05 < V <= 1.10
    * `:alert`    -- 0.85 <= V < 0.90 or V > 1.10
    * `:critical` -- V < 0.85

  Normal buses are excluded from the result.  The list is sorted by voltage
  magnitude ascending (worst violations first).
  """
  def check_voltages(solution) do
    solution
    |> bus_voltage_pairs()
    |> Enum.map(fn {bus_id, vm} ->
      %{bus_id: bus_id, vm_pu: vm, status: classify_voltage(vm)}
    end)
    |> Enum.reject(fn %{status: s} -> s == :normal end)
    |> Enum.sort_by(fn %{vm_pu: v} -> v end)
  end

  @doc """
  Compute a voltage stability proximity index.

  Returns a float from 0.0 (healthy -- all buses at or above 1.0 pu) to
  1.0 (collapse imminent -- minimum bus voltage at or below 0.8 pu).
  The mapping is linear between 1.0 pu and 0.8 pu.
  """
  def collapse_proximity(solution) do
    pairs = bus_voltage_pairs(solution)

    if pairs == [] do
      0.0
    else
      min_v = pairs |> Enum.map(&elem(&1, 1)) |> Enum.min()

      cond do
        min_v >= 1.0 -> 0.0
        min_v <= 0.8 -> 1.0
        true -> (1.0 - min_v) / 0.2
      end
    end
  end

  @doc """
  Compute reactive power margin for a single bus.

  Returns `%{bus_id, vm_pu, q_margin_mvar}` or `nil` if the bus is not found
  in the solution.  The margin is a simplified linear approximation: each
  0.01 pu of voltage headroom above 0.90 pu corresponds to roughly 10 Mvar
  of additional reactive demand the bus can absorb before entering the
  undervoltage region.
  """
  def reactive_margin(solution, bus_id) do
    case bus_vm(solution, bus_id) do
      nil ->
        nil

      vm ->
        margin = max((vm - 0.90) * 1000.0, 0.0)
        %{bus_id: bus_id, vm_pu: vm, q_margin_mvar: Float.round(margin, 1)}
    end
  end

  @doc """
  Identify buses at risk of voltage collapse.

  Returns buses whose voltage magnitude is below `threshold` (default 0.92 pu),
  sorted by voltage ascending (worst first).
  """
  def at_risk_buses(solution, threshold \\ 0.92) do
    solution
    |> bus_voltage_pairs()
    |> Enum.filter(fn {_id, vm} -> vm < threshold end)
    |> Enum.map(fn {id, vm} -> %{bus_id: id, vm_pu: vm} end)
    |> Enum.sort_by(fn %{vm_pu: v} -> v end)
  end

  defp classify_voltage(vm) do
    cond do
      vm < 0.85 -> :critical
      vm < 0.90 -> :alert
      vm < 0.95 -> :warning
      vm > 1.10 -> :alert
      vm > 1.05 -> :warning
      true -> :normal
    end
  end
end
