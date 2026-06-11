defmodule PowerModel.Failure.Contingency do
  @moduledoc """
  N-1 Contingency screening using Line Outage Distribution Factors (LODF).
  Screens all branches without re-solving power flow.
  """

  @doc """
  Compute LODF matrix from base case DC solution.
  LODF(l,k) = change in flow on line l when line k is tripped,
  as a fraction of the pre-outage flow on line k.
  """
  def compute_lodf(lines, bus_index, b_prime_inv, _base_mva) do
    n_lines = length(lines)

    ptdf = compute_ptdf(lines, bus_index, b_prime_inv)

    lodf =
      for l <- 0..(n_lines - 1) do
        for k <- 0..(n_lines - 1) do
          if l == k do
            -1.0
          else
            line_k = Enum.at(lines, k)
            from_k = Map.get(bus_index, line_k.from_bus_id)
            to_k = Map.get(bus_index, line_k.to_bus_id)

            ptdf_k_self = safe_ptdf(ptdf, k, from_k) - safe_ptdf(ptdf, k, to_k)
            denom = 1.0 - ptdf_k_self

            if abs(denom) < 1.0e-10 do
              0.0
            else
              ptdf_l_from = safe_ptdf(ptdf, l, from_k)
              ptdf_l_to = safe_ptdf(ptdf, l, to_k)
              (ptdf_l_from - ptdf_l_to) / denom
            end
          end
        end
      end

    lodf
  end

  @doc """
  Screen all N-1 contingencies using LODF.
  Returns list of {line_id, violations} for lines causing overloads.
  """
  def screen_n1(lines, base_flows, lodf, rating_threshold \\ 1.0) do
    Enum.with_index(lines)
    |> Enum.flat_map(fn {outaged_line, k} ->
      violations =
        Enum.with_index(lines)
        |> Enum.filter(fn {monitored_line, l} ->
          l != k and monitored_line.rating_a_mva != nil
        end)
        |> Enum.filter(fn {monitored_line, l} ->
          base_flow = Map.get(base_flows, {:line, monitored_line.id}, %{})
          base_mw = abs(base_flow[:p_flow_mw] || 0.0)

          outaged_flow = Map.get(base_flows, {:line, outaged_line.id}, %{})
          outaged_mw = abs(outaged_flow[:p_flow_mw] || 0.0)

          lodf_val = Enum.at(Enum.at(lodf, l), k)
          post_flow = base_mw + lodf_val * outaged_mw

          abs(post_flow) > monitored_line.rating_a_mva * rating_threshold
        end)
        |> Enum.map(fn {monitored_line, l} ->
          base_flow = Map.get(base_flows, {:line, monitored_line.id}, %{})
          base_mw = abs(base_flow[:p_flow_mw] || 0.0)

          outaged_flow = Map.get(base_flows, {:line, outaged_line.id}, %{})
          outaged_mw = abs(outaged_flow[:p_flow_mw] || 0.0)

          lodf_val = Enum.at(Enum.at(lodf, l), k)
          post_flow = base_mw + lodf_val * outaged_mw

          %{
            outaged_line_id: outaged_line.id,
            monitored_line_id: monitored_line.id,
            pre_outage_flow_mw: base_mw,
            post_outage_flow_mw: abs(post_flow),
            rating_mva: monitored_line.rating_a_mva,
            loading_pct: abs(post_flow) / monitored_line.rating_a_mva * 100.0
          }
        end)

      if Enum.empty?(violations) do
        []
      else
        [{outaged_line.id, violations}]
      end
    end)
  end

  defp compute_ptdf(lines, bus_index, b_prime_inv) do
    n_reduced = length(b_prime_inv)
    if n_reduced == 0, do: throw({:error, :empty_b_prime_inv})

    Enum.map(lines, fn line ->
      from_idx = Map.get(bus_index, line.from_bus_id)
      to_idx = Map.get(bus_index, line.to_bus_id)
      x = line.x_pu || 0.001
      b_line = 1.0 / x

      for n <- 0..(n_reduced - 1) do
        inv_from =
          if from_idx != nil and from_idx < n_reduced do
            Enum.at(Enum.at(b_prime_inv, from_idx, []), n, 0.0)
          else
            0.0
          end

        inv_to =
          if to_idx != nil and to_idx < n_reduced do
            Enum.at(Enum.at(b_prime_inv, to_idx, []), n, 0.0)
          else
            0.0
          end

        b_line * (inv_from - inv_to)
      end
    end)
  end

  defp safe_ptdf(ptdf, line_idx, bus_idx) do
    case Enum.at(ptdf, line_idx) do
      nil ->
        0.0

      row ->
        case bus_idx do
          nil -> 0.0
          idx -> Enum.at(row, idx) || 0.0
        end
    end
  end
end
