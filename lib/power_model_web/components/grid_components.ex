defmodule PowerModelWeb.GridComponents do
  @moduledoc """
  Reusable function components for grid visualization elements.
  """
  use Phoenix.Component

  attr :value, :float, required: true
  attr :max, :float, default: 100.0
  attr :class, :string, default: ""

  def loading_bar(assigns) do
    pct = min(assigns.value / assigns.max * 100, 100)
    color = cond do
      pct < 50 -> "#2ecc71"
      pct < 75 -> "#f1c40f"
      pct < 90 -> "#e67e22"
      true -> "#e74c3c"
    end

    assigns = assign(assigns, pct: pct, color: color)

    ~H"""
    <div class={"loading-bar " <> @class}>
      <div class="loading-fill" style={"width: #{@pct}%; background: #{@color}"}></div>
      <span class="loading-text"><%= Float.round(@pct, 1) %>%</span>
    </div>
    """
  end

  attr :voltage, :float, required: true

  def voltage_badge(assigns) do
    color = voltage_color(assigns.voltage)
    assigns = assign(assigns, color: color)

    ~H"""
    <span class="voltage-badge" style={"background: #{@color}"}>
      <%= Float.round(@voltage, 1) %> kV
    </span>
    """
  end

  attr :state, :string, required: true

  def state_indicator(assigns) do
    {color, label} = state_style(assigns.state)
    assigns = assign(assigns, color: color, label: label)

    ~H"""
    <span class="state-indicator">
      <span class="state-dot" style={"background: #{@color}"}></span>
      <%= @label %>
    </span>
    """
  end

  attr :fuel, :string, required: true

  def fuel_badge(assigns) do
    {color, label} = fuel_style(assigns.fuel)
    assigns = assign(assigns, color: color, label: label)

    ~H"""
    <span class="fuel-badge" style={"background: #{@color}20; color: #{@color}; border: 1px solid #{@color}40"}>
      <%= @label %>
    </span>
    """
  end

  attr :mw, :float, required: true

  def power_display(assigns) do
    {value, unit} = if assigns.mw >= 1000 do
      {Float.round(assigns.mw / 1000.0, 2), "GW"}
    else
      {Float.round(assigns.mw, 1), "MW"}
    end

    assigns = assign(assigns, value: value, unit: unit)

    ~H"""
    <span class="power-display">
      <span class="power-value"><%= @value %></span>
      <span class="power-unit"><%= @unit %></span>
    </span>
    """
  end

  defp voltage_color(kv) when kv >= 500, do: "#dc143c"
  defp voltage_color(kv) when kv >= 345, do: "#ff8c00"
  defp voltage_color(kv) when kv >= 230, do: "#32cd32"
  defp voltage_color(kv) when kv >= 138, do: "#40e0d0"
  defp voltage_color(kv) when kv >= 69, do: "#6495ed"
  defp voltage_color(_), do: "#888"

  defp state_style("in_service"), do: {"#2ecc71", "In Service"}
  defp state_style("tripped"), do: {"#e74c3c", "Tripped"}
  defp state_style("overloaded"), do: {"#e74c3c", "Overloaded"}
  defp state_style("stressed"), do: {"#f5a623", "Stressed"}
  defp state_style("out_of_service"), do: {"#555", "Out of Service"}
  defp state_style(_), do: {"#888", "Unknown"}

  defp fuel_style("NG"), do: {"#4183d7", "Gas"}
  defp fuel_style("NUC"), do: {"#9b59b6", "Nuclear"}
  defp fuel_style("WAT"), do: {"#3498db", "Hydro"}
  defp fuel_style("WND"), do: {"#2ecc71", "Wind"}
  defp fuel_style("SUN"), do: {"#f1c40f", "Solar"}
  defp fuel_style("SUB"), do: {"#555", "Coal"}
  defp fuel_style("BIT"), do: {"#444", "Coal"}
  defp fuel_style("GEO"), do: {"#e67e22", "Geo"}
  defp fuel_style(ft), do: {"#888", ft || "Unknown"}
end
