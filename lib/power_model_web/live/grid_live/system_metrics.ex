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
        <span class="metric-label">Load</span>
        <span class="metric-value"><%= format_mw(@metrics.total_load_mw) %></span>
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

  defp format_mw(mw) when mw >= 1000, do: "#{:erlang.float_to_binary(mw / 1000.0, decimals: 1)} GW"
  defp format_mw(mw), do: "#{:erlang.float_to_binary(mw * 1.0, decimals: 0)} MW"

  defp freq_class(hz) when hz >= 59.95, do: "freq-normal"
  defp freq_class(hz) when hz >= 59.5, do: "freq-warning"
  defp freq_class(_), do: "freq-critical"
end
