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
    :mismatch_mw
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
        mismatch_mw: nil
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
  """
  def energy_balance(%__MODULE__{} = s, tol_mw \\ 1.0) do
    residual = (s.total_gen_mw || 0.0) - (s.total_load_mw || 0.0) - (s.total_loss_mw || 0.0)
    %{residual_mw: residual, ok: abs(residual) <= tol_mw}
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
