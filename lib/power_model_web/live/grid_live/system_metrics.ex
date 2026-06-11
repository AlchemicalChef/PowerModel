defmodule PowerModelWeb.GridLive.SystemMetrics do
  use PowerModelWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="metrics-panel">
      <div class="metric">
        <span class="metric-label">Generation</span>
        <span class="metric-value"><%= format_mw(@metrics.total_gen_mw) %></span>
      </div>
      <div class="metric">
        <span class="metric-label">Load (served)</span>
        <span class="metric-value">
          <%= format_mw(served_mw(@metrics)) %><%= if demand_mw(@metrics) > 0.0 do %>
            <span class="metric-sub">of <%= format_mw(demand_mw(@metrics)) %></span>
          <% end %>
        </span>
      </div>
      <div :if={shed_total_mw(@metrics) > 0.0} class="metric">
        <span class="metric-label">Shed</span>
        <span class="metric-value text-red"><%= format_mw(shed_total_mw(@metrics)) %></span>
      </div>
      <div class="metric">
        <span class="metric-label">Overloads</span>
        <span class={"metric-value " <> if(overload(@metrics).overloaded_count > 0, do: "text-red", else: "")}>
          <%= overload(@metrics).overloaded_count %><%= if overload(@metrics).overloaded_count > 0 do %>
            (max <%= :erlang.float_to_binary(overload(@metrics).max_loading_pct * 1.0, decimals: 0) %>%)
          <% end %><%= if overload(@metrics).unrated_count > 0 do %>
            <span class="metric-sub"><%= overload(@metrics).unrated_count %> unrated</span>
          <% end %>
        </span>
      </div>
      <div :if={abs(mismatch_mw(@metrics)) > 1.0} class="metric">
        <span class="metric-label">Mismatch</span>
        <span class="metric-value freq-warning"><%= format_mw(mismatch_mw(@metrics)) %></span>
      </div>
      <div class="metric">
        <span class="metric-label">Frequency</span>
        <span class={"metric-value " <> freq_class(@metrics.frequency_hz)}>
          <%= :erlang.float_to_binary(@metrics.frequency_hz, decimals: 2) %> Hz
        </span>
      </div>
      <div class="metric">
        <span class="metric-label">Islands</span>
        <span class="metric-value"><%= @metrics.islands %></span>
      </div>
      <div class="metric">
        <span class="metric-label">Tripped</span>
        <span class={"metric-value " <> if(@metrics.tripped_count > 0, do: "text-red", else: "")}>
          <%= @metrics.tripped_count %>
        </span>
      </div>
    </div>
    """
  end

  # Served load: cascade balance when present, otherwise the solver total.
  defp served_mw(metrics) do
    case Map.get(metrics, :served_mw, 0.0) do
      v when is_number(v) and v > 0.0 -> v
      _ -> Map.get(metrics, :total_load_mw) || 0.0
    end
  end

  defp demand_mw(metrics), do: Map.get(metrics, :demand_mw) || 0.0

  defp shed_total_mw(metrics) do
    (Map.get(metrics, :shed_mw) || 0.0) + (Map.get(metrics, :blackout_mw) || 0.0)
  end

  defp mismatch_mw(metrics) do
    case Map.get(metrics, :mismatch_mw) do
      v when is_number(v) -> v
      _ -> 0.0
    end
  end

  @empty_overload %{
    overloaded_count: 0,
    max_loading_pct: 0.0,
    overload_mw: 0.0,
    monitored_count: 0,
    unrated_count: 0
  }

  defp overload(metrics), do: Map.get(metrics, :overload) || @empty_overload

  defp format_mw(nil), do: "—"
  defp format_mw(mw) when mw >= 1000 or mw <= -1000,
    do: "#{:erlang.float_to_binary(mw / 1000.0, decimals: 1)} GW"
  defp format_mw(mw), do: "#{:erlang.float_to_binary(mw * 1.0, decimals: 0)} MW"

  defp freq_class(hz) when hz >= 59.95, do: "freq-normal"
  defp freq_class(hz) when hz >= 59.5, do: "freq-warning"
  defp freq_class(_), do: "freq-critical"
end
