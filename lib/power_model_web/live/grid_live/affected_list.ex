defmodule PowerModelWeb.GridLive.AffectedList do
  @moduledoc """
  The rolling feed of what the cascade has taken out.

  Two things about this panel were wrong before Wave 3b (REVIEW UIW-5/UIW-7).

  **It showed the oldest fifty events.** The list arrives chronologically and
  the panel took the first fifty of it, so on any cascade longer than fifty
  events the terminal phase -- the undervoltage trips, the UVLS stages, the
  ride-through dropouts -- could never appear. It is newest-first now, and the
  parent maintains the feed incrementally instead of re-flattening every event
  of every step on every render.

  **Most causes had no colour.** `cause_class/1` knew seven strings while the
  engine emitted twenty-odd, so the new protection and DER events rendered
  with no left border at all. The families below cover the emitted vocabulary;
  anything unrecognised gets a neutral class rather than an empty one, so a
  cause added later is dull rather than invisible.

  The server aggregates per-load shedding into one synthetic `"island"` event
  per cause per step (a collapse emits 11,304 of them otherwise). Those rows
  carry `details.aggregated` and render their count and shed MW in place of a
  component id.
  """

  use PowerModelWeb, :live_component

  @visible 50

  defp visible, do: @visible

  def render(assigns) do
    ~H"""
    <div class="affected-panel">
      <div class="affected-header">
        <h4>Affected Components</h4>
        <span class="affected-count">{@total}</span>
      </div>

      <div class="affected-scroll">
        <div
          :for={event <- Enum.take(@events, visible())}
          class={"affected-item " <> cause_class(event.failure_cause)}
        >
          <div class="affected-icon">{type_icon(event.component_type)}</div>
          <div class="affected-info">
            <span class="affected-type">{humanize(event.component_type)}</span>
            <span class="affected-id">{identity(event)}</span>
          </div>
          <div class="affected-cause">
            <span class="cause-badge">{humanize(event.failure_cause)}</span>
            <span class="affected-step">Step {event[:step] || "?"}</span>
          </div>
        </div>

        <%!-- UI-L17: the shortfall between the feed and the total is two
              different things, and reading the second as the first is the
              mistake worth preventing. Most of it is older events, still in
              the session and reachable by scrolling. The `omitted` part is
              events the server never sent at all -- the 200-per-step
              itemisation cap -- so no amount of scrolling reaches them. The
              cap reserves a slot for the first event of every cause, so
              every mechanism that fired is still represented. --%>
        <div :if={@total > visible()} class="affected-overflow">
          + {@total - visible()} more<span :if={@omitted > 0} class="affected-omitted">
            · {@omitted} not itemised</span>
        </div>
      </div>
    </div>
    """
  end

  # An aggregate names a group, not a component: showing "#4126" for 5,650
  # shed loads would read as one load. The island bus id is still the
  # identifier the row is keyed on; the count and MW are what the reader
  # needs.
  defp identity(%{details: %{aggregated: true} = details}) do
    "#{details[:count]} loads · #{format_mw(details[:shed_mw])}"
  end

  defp identity(event), do: "##{event.component_id}"

  defp format_mw(mw) when is_number(mw) and mw >= 1000,
    do: "#{:erlang.float_to_binary(mw / 1000.0, decimals: 1)} GW"

  defp format_mw(mw) when is_number(mw),
    do: "#{:erlang.float_to_binary(mw * 1.0, decimals: 0)} MW"

  defp format_mw(_), do: "—"

  # Frequency-driven: the swing equation took it, or UFLS gave up load to
  # arrest the decline.
  defp cause_class("ufls_shed"), do: "cause-ufls"
  defp cause_class("ufls"), do: "cause-ufls"
  defp cause_class("underfrequency_trip"), do: "cause-ufls"
  defp cause_class("overfrequency_trip"), do: "cause-ufls"
  defp cause_class("generator_frequency_trips"), do: "cause-ufls"

  # Voltage-driven. UVLS belongs here and not with UFLS: it is shedding
  # ordered by a voltage collapse, and the whole point of separating the two
  # stages is being able to see which mechanism took the load.
  defp cause_class("uvls_shed"), do: "cause-voltage"
  defp cause_class("undervoltage_trip"), do: "cause-voltage"
  defp cause_class("overvoltage_trip"), do: "cause-voltage"
  defp cause_class("voltage_violation"), do: "cause-voltage"
  defp cause_class("generator_voltage_trips"), do: "cause-voltage"

  # Thermal and the distance relays that clear the resulting faults.
  defp cause_class("thermal_overload"), do: "cause-thermal"
  defp cause_class("conductor_thermal"), do: "cause-thermal"
  defp cause_class("zone3_relay"), do: "cause-thermal"
  # protection.ex builds this one as "distance_zone#{result.zone}".
  defp cause_class("distance_zone" <> _zone), do: "cause-thermal"

  # Distributed energy resources riding through, or not.
  defp cause_class("btm_trip"), do: "cause-der"
  defp cause_class("btm_voltage_trip"), do: "cause-der"

  defp cause_class("manual_trip"), do: "cause-manual"

  defp cause_class("island_blackout"), do: "cause-blackout"
  defp cause_class("power_loss"), do: "cause-blackout"
  defp cause_class("island_solve_failed"), do: "cause-blackout"
  defp cause_class("max_steps_exhausted"), do: "cause-blackout"

  # Never "": an unrecognised cause must still draw as a row, in a colour that
  # claims nothing about which mechanism fired.
  defp cause_class(_), do: "cause-unknown"

  defp type_icon("transmission_line"), do: "⚡"
  defp type_icon("generator"), do: "⚙"
  defp type_icon("transformer"), do: "🔌"
  defp type_icon("load"), do: "💡"
  defp type_icon("bus"), do: "●"
  defp type_icon("water_facility"), do: "💧"
  defp type_icon("datacenter"), do: "🖥"
  defp type_icon("island"), do: "🏝"
  defp type_icon("btm_solar"), do: "☀"
  defp type_icon("cascade"), do: "⟶"
  defp type_icon(_), do: "•"

  defp humanize(str) when is_binary(str) do
    str |> String.replace("_", " ") |> String.capitalize()
  end

  defp humanize(_), do: ""
end
