defmodule PowerModelWeb.GridLive.InfoPanel do
  use PowerModelWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="info-panel">
      <div class="info-header">
        <h3><%= component_title(@component.type) %> #<%= @component.id %></h3>
        <button phx-click="deselect" class="close-btn">&times;</button>
      </div>

      <div class="info-body">
        <div class="info-row">
          <span class="info-label">Type</span>
          <span class="info-value"><%= humanize_type(@component.type) %></span>
        </div>
        <div class="info-row">
          <span class="info-label">ID</span>
          <span class="info-value"><%= @component.id %></span>
        </div>
        <%= if @component[:capacity] do %>
          <div class="info-row">
            <span class="info-label">Capacity</span>
            <span class="info-value"><%= format_number(@component.capacity) %> MW</span>
          </div>
        <% end %>
        <%= if @component[:fuel_type] do %>
          <div class="info-row">
            <span class="info-label">Fuel Type</span>
            <span class="info-value"><%= @component.fuel_type %></span>
          </div>
        <% end %>
        <%= if @component[:voltage_kv] do %>
          <div class="info-row">
            <span class="info-label">Voltage</span>
            <span class="info-value"><%= @component.voltage_kv %> kV</span>
          </div>
        <% end %>
        <%= if @component[:rating_mva] do %>
          <div class="info-row">
            <span class="info-label">Rating</span>
            <span class="info-value"><%= @component.rating_mva %> MVA</span>
          </div>
        <% end %>
        <%= if @component[:voltage] do %>
          <div class="info-row">
            <span class="info-label">Max Voltage</span>
            <span class="info-value"><%= @component.voltage %> kV</span>
          </div>
        <% end %>
        <%!-- Water facility fields --%>
        <%= if @component[:facility_type] do %>
          <div class="info-row">
            <span class="info-label">Facility</span>
            <span class="info-value"><%= @component.facility_type %></span>
          </div>
        <% end %>
        <%= if @component[:power_mw] do %>
          <div class="info-row">
            <span class="info-label">Power Draw</span>
            <span class="info-value"><%= format_number(@component.power_mw) %> MW</span>
          </div>
        <% end %>
        <%= if @component[:bus_id] do %>
          <div class="info-row">
            <span class="info-label">Grid Bus</span>
            <span class="info-value">Bus #<%= @component.bus_id %></span>
          </div>
        <% end %>
        <%= if @component[:state] do %>
          <div class="info-row">
            <span class="info-label">State</span>
            <span class="info-value"><%= state_name(@component.state) %></span>
          </div>
        <% end %>
        <%= if @component[:data_source] do %>
          <div class="info-row info-source">
            <span class="info-label">Source</span>
            <span class="info-value source-value"><%= @component.data_source %></span>
          </div>
        <% end %>
      </div>

      <div class="info-actions">
        <%= if can_trip?(@component.type) and not @cascade_active do %>
          <button
            phx-click="inject_failure"
            phx-value-type={@component.type}
            phx-value-id={@component.id}
            class="trip-btn"
          >
            Inject Failure
          </button>
        <% end %>

        <%= if @cascade_active do %>
          <div class="cascade-indicator">
            <span class="cascade-dot"></span>
            Cascade in progress...
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp component_title("transmission_line"), do: "Line"
  defp component_title("generator"), do: "Generator"
  defp component_title("substation"), do: "Substation"
  defp component_title("transformer"), do: "Transformer"
  defp component_title("water_facility"), do: "Water"
  defp component_title(type), do: String.capitalize(type)

  defp humanize_type("transmission_line"), do: "Transmission Line"
  defp humanize_type("water_facility"), do: "Water Facility"
  defp humanize_type(type), do: String.capitalize(type)

  defp can_trip?("transmission_line"), do: true
  defp can_trip?("generator"), do: true
  defp can_trip?("transformer"), do: true
  defp can_trip?(_), do: false

  defp state_name(0), do: "Normal"
  defp state_name(1), do: "Stressed"
  defp state_name(2), do: "Overloaded"
  defp state_name(3), do: "Tripped"
  defp state_name(_), do: "Unknown"

  defp format_number(nil), do: "—"
  defp format_number(v) when is_float(v), do: Float.round(v, 1)
  defp format_number(v) when is_integer(v), do: v
  defp format_number(v), do: v
end
