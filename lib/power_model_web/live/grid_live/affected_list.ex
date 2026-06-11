defmodule PowerModelWeb.GridLive.AffectedList do
  use PowerModelWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="affected-panel">
      <div class="affected-header">
        <h4>Affected Components</h4>
        <span class="affected-count">
          {length(@events) + length(@compensating_lines)}
        </span>
      </div>

      <div class="affected-scroll">
        <%!-- Tripped components (from cascade) --%>
        <%= for event <- Enum.take(@events, 20) do %>
          <div class={"affected-item " <> cause_class(event.failure_cause)}>
            <div class="affected-icon">{type_icon(event.component_type)}</div>
            <div class="affected-info">
              <span class="affected-type">{humanize(event.component_type)}</span>
              <span class="affected-id">#{event.component_id}</span>
            </div>
            <div class="affected-cause">
              <span class="cause-badge">{humanize(event.failure_cause)}</span>
            </div>
          </div>
        <% end %>

        <%!-- Compensating lines (from DC power flow redistribution) --%>
        <%= if @compensating_lines != [] do %>
          <div class="affected-section-header">
            Compensating Lines
            <span class="affected-section-count">{length(@compensating_lines)}</span>
          </div>

          <%= for line <- Enum.take(@compensating_lines, 50) do %>
            <div class={"affected-item comp-" <> (line.status || "compensating")}>
              <div class="affected-icon">⚡</div>
              <div class="affected-info">
                <span class="comp-route">
                  {line.sub_1 || "?"} → {line.sub_2 || "?"}
                </span>
                <span class="comp-meta">
                  {if line.voltage_kv, do: "#{round(line.voltage_kv)} kV", else: ""}
                  {if line.owner, do: " · #{line.owner}", else: ""}
                </span>
              </div>
              <div class="comp-loading">
                <div class="comp-bar-container">
                  <div
                    class={"comp-bar " <> (line.status || "compensating")}
                    style={"width: #{min(line.loading_pct, 100)}%"}
                  >
                  </div>
                </div>
                <span class="comp-pct">{line.loading_pct}%</span>
                <span class="comp-delta">+{line.delta}%</span>
              </div>
            </div>
          <% end %>
        <% end %>

        <%= if length(@events) > 20 do %>
          <div class="affected-overflow">
            + {length(@events) - 20} more tripped
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp cause_class("thermal_overload"), do: "cause-thermal"
  defp cause_class("zone3_relay"), do: "cause-thermal"
  defp cause_class("undervoltage"), do: "cause-voltage"
  defp cause_class("overvoltage"), do: "cause-voltage"
  defp cause_class("ufls_shed"), do: "cause-ufls"
  defp cause_class("uvls"), do: "cause-ufls"
  defp cause_class("manual_trip"), do: "cause-manual"
  defp cause_class("island_blackout"), do: "cause-blackout"
  defp cause_class("power_loss"), do: "cause-blackout"
  defp cause_class(_), do: ""

  defp type_icon("transmission_line"), do: "⚡"
  defp type_icon("generator"), do: "⚙"
  defp type_icon("transformer"), do: "🔌"
  defp type_icon("load"), do: "💡"
  defp type_icon("bus"), do: "●"
  defp type_icon(_), do: "•"

  defp humanize(str) when is_binary(str) do
    str |> String.replace("_", " ") |> String.capitalize()
  end

  defp humanize(_), do: ""
end
