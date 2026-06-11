defmodule PowerModelWeb.GridLive.InfoPanel do
  use PowerModelWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="info-panel">
      <div class="info-header">
        <h3>{component_title(@component.type)} #{@component.id}</h3>
        <button phx-click="deselect" class="close-btn">&times;</button>
      </div>

      <div class="info-body">
        <div class="info-row">
          <span class="info-label">Type</span>
          <span class="info-value">{humanize_type(@component.type)}</span>
        </div>
        <div class="info-row">
          <span class="info-label">ID</span>
          <span class="info-value">{@component.id}</span>
        </div>
        <%= if @component[:capacity] do %>
          <div class="info-row">
            <span class="info-label">Capacity</span>
            <span class="info-value">{format_number(@component.capacity)} MW</span>
          </div>
        <% end %>
        <%= if @component[:fuel_type] do %>
          <div class="info-row">
            <span class="info-label">Fuel Type</span>
            <span class="info-value">{@component.fuel_type}</span>
          </div>
        <% end %>
        <%= if @component[:voltage_kv] do %>
          <div class="info-row">
            <span class="info-label">Voltage</span>
            <span class="info-value">{@component.voltage_kv} kV</span>
          </div>
        <% end %>
        <%= if @component[:rating_mva] do %>
          <div class="info-row">
            <span class="info-label">Rating</span>
            <span class="info-value">{@component.rating_mva} MVA</span>
          </div>
        <% end %>
        <%= if @component[:voltage] do %>
          <div class="info-row">
            <span class="info-label">Max Voltage</span>
            <span class="info-value">{@component.voltage} kV</span>
          </div>
        <% end %>
        <%!-- Critical facility fields --%>
        <%= if @component[:category] do %>
          <div class="info-row">
            <span class="info-label">Category</span>
            <span class="info-value">{@component.category}</span>
          </div>
        <% end %>
        <%= if @component[:address] do %>
          <div class="info-row">
            <span class="info-label">Address</span>
            <span class="info-value">{@component.address}</span>
          </div>
        <% end %>
        <%= if @component[:beds] do %>
          <div class="info-row">
            <span class="info-label">Beds</span>
            <span class="info-value">{@component.beds}</span>
          </div>
        <% end %>
        <%= if @component[:trauma] do %>
          <div class="info-row">
            <span class="info-label">Trauma Level</span>
            <span class="info-value">{@component.trauma}</span>
          </div>
        <% end %>
        <%!-- Water facility fields --%>
        <%= if @component[:facility_type] do %>
          <div class="info-row">
            <span class="info-label">Facility</span>
            <span class="info-value">{@component.facility_type}</span>
          </div>
        <% end %>
        <%= if @component[:power_mw] do %>
          <div class="info-row">
            <span class="info-label">Power Draw</span>
            <span class="info-value">{format_number(@component.power_mw)} MW</span>
          </div>
        <% end %>
        <%= if @component[:bus_id] do %>
          <div class="info-row">
            <span class="info-label">Grid Bus</span>
            <span class="info-value">Bus #{@component.bus_id}</span>
          </div>
        <% end %>
        <%= if @component[:state] do %>
          <div class="info-row">
            <span class="info-label">State</span>
            <span class="info-value">{state_name(@component.state)}</span>
          </div>
        <% end %>
        <%= if @component[:data_source] do %>
          <div class="info-row info-source">
            <span class="info-label">Source</span>
            <span class="info-value source-value">{@component.data_source}</span>
          </div>
        <% end %>
      </div>

      <%!-- Harmonics controls for generators --%>
      <%= if @component.type == "generator" and not @cascade_active do %>
        <div class="info-section harmonics-section">
          <div class="info-section-header">
            <span class="section-title">Harmonics</span>
          </div>

          <div class="harmonic-controls">
            <div class="harmonic-row">
              <label>Source Type</label>
              <select
                phx-change="harmonic_source_type"
                phx-value-gen-id={@component.id}
              >
                <option value="none" selected={harmonic_type(@component) == "none"}>None</option>
                <option value="pwm_inverter" selected={harmonic_type(@component) == "pwm_inverter"}>
                  PWM Inverter
                </option>
                <option value="six_pulse" selected={harmonic_type(@component) == "six_pulse"}>
                  6-Pulse Converter
                </option>
                <option value="twelve_pulse" selected={harmonic_type(@component) == "twelve_pulse"}>
                  12-Pulse Converter
                </option>
                <option value="arc_furnace" selected={harmonic_type(@component) == "arc_furnace"}>
                  Arc Furnace
                </option>
              </select>
            </div>

            <%= if Map.get(@component, :harmonic_type, "none") != "none" do %>
              <div class="harmonic-row">
                <label>5th Harmonic</label>
                <div class="slider-group">
                  <input
                    type="range"
                    min="0"
                    max="15"
                    step="0.5"
                    value={Map.get(@component, :h5_pct, default_h5(@component))}
                    phx-change="harmonic_adjust"
                    phx-value-gen-id={@component.id}
                    phx-value-harmonic="5"
                  />
                  <span class="slider-value">
                    {Map.get(@component, :h5_pct, default_h5(@component))}%
                  </span>
                </div>
              </div>

              <div class="harmonic-row">
                <label>7th Harmonic</label>
                <div class="slider-group">
                  <input
                    type="range"
                    min="0"
                    max="12"
                    step="0.5"
                    value={Map.get(@component, :h7_pct, default_h7(@component))}
                    phx-change="harmonic_adjust"
                    phx-value-gen-id={@component.id}
                    phx-value-harmonic="7"
                  />
                  <span class="slider-value">
                    {Map.get(@component, :h7_pct, default_h7(@component))}%
                  </span>
                </div>
              </div>

              <div class="harmonic-row">
                <label>11th Harmonic</label>
                <div class="slider-group">
                  <input
                    type="range"
                    min="0"
                    max="8"
                    step="0.5"
                    value={Map.get(@component, :h11_pct, 2.0)}
                    phx-change="harmonic_adjust"
                    phx-value-gen-id={@component.id}
                    phx-value-harmonic="11"
                  />
                  <span class="slider-value">{Map.get(@component, :h11_pct, 2.0)}%</span>
                </div>
              </div>

              <button
                phx-click="run_harmonics"
                phx-value-gen-id={@component.id}
                class="harmonics-btn"
              >
                Analyze Harmonics
              </button>
            <% end %>
          </div>

          <%= if @component[:thd_result] do %>
            <div class="harmonic-results">
              <div class="info-row">
                <span class="info-label">Bus THD</span>
                <span class={"info-value #{if @component.thd_result > 5.0, do: "thd-violation", else: "thd-ok"}"}>
                  {Float.round(@component.thd_result, 2)}%
                </span>
              </div>
              <div class="info-row">
                <span class="info-label">IEEE 519</span>
                <span class={"info-value #{if @component[:ieee_519_compliant], do: "thd-ok", else: "thd-violation"}"}>
                  {if @component[:ieee_519_compliant], do: "Compliant", else: "Violation"}
                </span>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>

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
            <span class="cascade-dot"></span> Cascade in progress...
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
  defp component_title("critical_facility"), do: "Facility"
  defp component_title(type), do: String.capitalize(type)

  defp humanize_type("transmission_line"), do: "Transmission Line"
  defp humanize_type("water_facility"), do: "Water Facility"
  defp humanize_type("critical_facility"), do: "Critical Facility"
  defp humanize_type(type), do: String.capitalize(type)

  defp can_trip?("transmission_line"), do: true
  defp can_trip?("generator"), do: true
  defp can_trip?("transformer"), do: true
  defp can_trip?(_), do: false

  defp state_name(0), do: "Normal"
  defp state_name(1), do: "Stressed"
  defp state_name(2), do: "Overloaded"
  defp state_name(3), do: "Tripped"
  defp state_name(4), do: "Rerouted"
  defp state_name(5), do: "Shed"
  defp state_name(6), do: "Islanded"
  defp state_name(_), do: "Unknown"

  defp format_number(nil), do: "—"
  defp format_number(v) when is_float(v), do: Float.round(v, 1)
  defp format_number(v) when is_integer(v), do: v
  defp format_number(v), do: v

  defp harmonic_type(component) do
    Map.get(component, :harmonic_type) || default_harmonic_type(component)
  end

  defp default_harmonic_type(component) do
    case Map.get(component, :fuel_type) do
      ft when ft in ["Solar", "Wind"] -> "pwm_inverter"
      _ -> "none"
    end
  end

  defp default_h5(component) do
    case harmonic_type(component) do
      "pwm_inverter" -> 4.0
      "six_pulse" -> 20.0
      "twelve_pulse" -> 2.0
      "arc_furnace" -> 4.5
      _ -> 0.0
    end
  end

  defp default_h7(component) do
    case harmonic_type(component) do
      "pwm_inverter" -> 3.0
      "six_pulse" -> 14.3
      "twelve_pulse" -> 1.5
      "arc_furnace" -> 3.3
      _ -> 0.0
    end
  end
end
