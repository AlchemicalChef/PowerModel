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
    :total_loss_mw
  ]

  def new(bus_ids, vm_pu, va_rad, line_flows, base_mva) do
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
      total_loss_mw: 0.0
    }
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
