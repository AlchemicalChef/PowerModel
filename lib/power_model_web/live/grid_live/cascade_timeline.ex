defmodule PowerModelWeb.GridLive.CascadeTimeline do
  use PowerModelWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="timeline-panel" id="cascade-timeline" phx-hook="CascadeTimeline">
      <div class="timeline-header">
        <h4>Cascade Timeline</h4>
        <span class="step-count"><%= length(@steps) %> steps</span>
      </div>

      <div class="timeline-track">
        <%= for {step, idx} <- Enum.with_index(@steps) do %>
          <button
            class={"timeline-step " <> if(idx == length(@steps) - 1, do: "active", else: "")}
            phx-click="scrub_timeline"
            phx-value-step={step.step}
            title={"Step #{step.step}: #{step.trip_count} trips, #{step.islands} islands"}
          >
            <span class="step-num"><%= step.step %></span>
            <span class="step-trips"><%= step.trip_count %></span>
          </button>
        <% end %>

        <%= if @active do %>
          <div class="timeline-progress"></div>
        <% end %>
      </div>
    </div>
    """
  end
end
