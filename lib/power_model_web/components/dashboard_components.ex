defmodule PowerModelWeb.DashboardComponents do
  @moduledoc """
  Function components for dashboard-style metric displays.
  """
  use Phoenix.Component

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :subtitle, :string, default: nil
  attr :trend, :atom, default: nil, values: [:up, :down, :flat, nil]
  attr :color, :string, default: "#e0e0e0"

  def metric_card(assigns) do
    ~H"""
    <div class="dash-metric-card">
      <div class="dash-metric-title"><%= @title %></div>
      <div class="dash-metric-value" style={"color: #{@color}"}><%= @value %></div>
      <%= if @subtitle do %>
        <div class="dash-metric-subtitle">
          <%= if @trend do %>
            <span class={"trend-icon trend-#{@trend}"}><%= trend_icon(@trend) %></span>
          <% end %>
          <%= @subtitle %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :items, :list, required: true

  def breakdown_table(assigns) do
    ~H"""
    <div class="dash-breakdown">
      <div class="dash-breakdown-title"><%= @title %></div>
      <div class="dash-breakdown-items">
        <%= for item <- @items do %>
          <div class="dash-breakdown-row">
            <span class="dash-breakdown-dot" style={"background: #{item[:color] || "#888"}"}></span>
            <span class="dash-breakdown-label"><%= item.label %></span>
            <span class="dash-breakdown-value"><%= item.value %></span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :current, :float, required: true
  attr :total, :float, required: true

  def capacity_gauge(assigns) do
    pct = if assigns.total > 0, do: assigns.current / assigns.total * 100, else: 0
    pct = min(pct, 100)
    stroke_color = cond do
      pct < 60 -> "#2ecc71"
      pct < 80 -> "#f1c40f"
      true -> "#e74c3c"
    end

    assigns = assign(assigns, pct: pct, stroke_color: stroke_color)

    ~H"""
    <div class="capacity-gauge">
      <svg viewBox="0 0 36 36" class="gauge-svg">
        <path
          d="M18 2.0845 a 15.9155 15.9155 0 0 1 0 31.831 a 15.9155 15.9155 0 0 1 0 -31.831"
          fill="none"
          stroke="rgba(100,100,120,0.3)"
          stroke-width="3"
        />
        <path
          d="M18 2.0845 a 15.9155 15.9155 0 0 1 0 31.831 a 15.9155 15.9155 0 0 1 0 -31.831"
          fill="none"
          stroke={@stroke_color}
          stroke-width="3"
          stroke-dasharray={"#{@pct}, 100"}
        />
      </svg>
      <div class="gauge-text">
        <div class="gauge-pct"><%= Float.round(@pct, 0) %>%</div>
        <div class="gauge-label"><%= @label %></div>
      </div>
    </div>
    """
  end

  defp trend_icon(:up), do: "↑"
  defp trend_icon(:down), do: "↓"
  defp trend_icon(:flat), do: "→"
  defp trend_icon(_), do: ""
end
