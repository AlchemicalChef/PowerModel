defmodule PowerModelWeb.GridLive.AffectedList do
  use PowerModelWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="affected-panel">
      <div class="affected-header">
        <h4>Affected Components</h4>
        <span class="affected-count">{length(@events)}</span>
      </div>

      <div class="affected-scroll">
        <%= for event <- Enum.take(@events, 50) do %>
          <div class={"affected-item " <> cause_class(event.failure_cause)}>
            <div class="affected-icon">{type_icon(event.component_type)}</div>
            <div class="affected-info">
              <span class="affected-type">{humanize(event.component_type)}</span>
              <span class="affected-id">#{event.component_id}</span>
            </div>
            <div class="affected-cause">
              <span class="cause-badge">{humanize(event.failure_cause)}</span>
              <span class="affected-step">Step {event[:step] || "?"}</span>
            </div>
          </div>
        <% end %>

        <%= if length(@events) > 50 do %>
          <div class="affected-overflow">
            + {length(@events) - 50} more
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp cause_class("thermal_overload"), do: "cause-thermal"
  defp cause_class("undervoltage"), do: "cause-voltage"
  defp cause_class("overvoltage"), do: "cause-voltage"
  defp cause_class("ufls_shed"), do: "cause-ufls"
  defp cause_class("manual_trip"), do: "cause-manual"
  defp cause_class("island_blackout"), do: "cause-blackout"
  defp cause_class("power_loss"), do: "cause-blackout"
  defp cause_class(_), do: ""

  defp type_icon("transmission_line"), do: "⚡"
  defp type_icon("generator"), do: "⚙"
  defp type_icon("transformer"), do: "🔌"
  defp type_icon("load"), do: "💡"
  defp type_icon("bus"), do: "●"
  defp type_icon("water_facility"), do: "💧"
  defp type_icon("datacenter"), do: "🖥"
  defp type_icon(_), do: "•"

  defp humanize(str) when is_binary(str) do
    str |> String.replace("_", " ") |> String.capitalize()
  end

  defp humanize(_), do: ""
end
