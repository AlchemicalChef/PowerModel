defmodule PowerModelWeb.GridLive.CascadeTimeline do
  use PowerModelWeb, :live_component

  def render(assigns) do
    ~H"""
    <%!-- UI-L3: the CascadeTimeline JS hook was deleted; the DOM id stays. --%>
    <div class="timeline-panel" id="cascade-timeline">
      <div class="timeline-header">
        <h4>Cascade Timeline</h4>
        <span class="step-count">{length(@steps)} steps</span>
      </div>

      <div class="timeline-track">
        <%= for {step, idx} <- Enum.with_index(@steps) do %>
          <%!-- UI-H3 / contract #4: scrubbing indexes frames by ARRAY
               POSITION (idx). Step NUMBERS restart at every manual trip, so
               they are ambiguous across cascades in one session.

               UI-M19: disabled while the cascade is still running. Rewinding
               a timeline that is still being appended to desynced the map
               permanently (the skipped frames' trip marks were never
               restored), and the client refuses the scrub for that reason —
               so the button must not offer it either. --%>
          <button
            id={"timeline-step-#{idx}"}
            class={"timeline-step " <> if(idx == length(@steps) - 1, do: "active", else: "")}
            phx-click="scrub_timeline"
            phx-value-step={idx}
            disabled={@active}
            title={
              if @active,
                do: "Timeline review is available once the cascade settles",
                else: "Step #{step.step}: #{step.trip_count} trips, #{step.islands} islands"
            }
          >
            <span class="step-num">{step.step}</span>
            <span class="step-trips">{step.trip_count}</span>
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
