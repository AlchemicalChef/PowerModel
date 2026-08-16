defmodule PowerModelWeb.GridLive.SystemMetrics do
  @moduledoc """
  The top-right summary panel.

  Three of its readings are the Wave 3b accounting the display used to drop
  (REVIEW UIW-3/UIW-5/UIW-6):

    * **Frequency is two numbers, not one.** The panel used to latch the
      minimum and never release it, so a cascade AGC had walked back to
      60.00 Hz kept showing its nadir in critical red forever. Current
      frequency is the headline; the nadir is a sub-label, because the dip is
      what armed UFLS and tripped the legacy rooftop fleet and it stays worth
      reading after the system recovers.

    * **Rooftop PV that trips is demand the wire stops seeing.** The engine's
      conservation identity is `served + shed + blackout == original +
      btm_tripped`; showing the first three against `original` alone
      over-counts by exactly the BTM amount, so the denominator carries it.

    * **AC coverage is partial and must say so.** `voltage_layer` counts the
      islands that reached an AC solution against those that ran DC-only.
      Voltage relays are inert in the DC-only ones, so "N/M islands" is a
      statement about how much of the picture has voltage in it at all.

  Every one of these renders only when the payload carried it. A missing key
  means "no information" and never zero -- reporting a zeroed AGC summary for
  a cascade with no secondary control is indistinguishable from a controller
  that ran out of reserve.
  """

  use PowerModelWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="metrics-panel">
      <div class="metric">
        <span class="metric-label">Generation</span>
        <span class="metric-value">{format_mw(@metrics.total_gen_mw)}</span>
      </div>
      <div class="metric">
        <span class="metric-label">Load (served)</span>
        <span class="metric-value">
          {format_mw(served_mw(@metrics))}
          <%= if demand_mw(@metrics) > 0.0 do %>
            <span class="metric-sub">
              of {format_mw(demand_mw(@metrics))}<span :if={btm_mw(@metrics) > 0.0} class="metric-btm">
                +{format_mw(btm_mw(@metrics))} BTM</span>
            </span>
          <% end %>
        </span>
      </div>
      <div :if={shed_total_mw(@metrics) > 0.0} class="metric">
        <span class="metric-label">Shed</span>
        <span class="metric-value text-red">{format_mw(shed_total_mw(@metrics))}</span>
      </div>
      <div :if={btm_mw(@metrics) > 0.0} class="metric">
        <span class="metric-label">BTM tripped</span>
        <span id="metric-btm" class="metric-value text-amber">
          {format_mw(btm_mw(@metrics))}
          <span :if={btm_breakdown(@metrics)} class="metric-sub">{btm_split_text(@metrics)}</span>
        </span>
      </div>
      <div class="metric">
        <span class="metric-label">Overloads</span>
        <span class={"metric-value " <> if(overload(@metrics).overloaded_count > 0, do: "text-red", else: "")}>
          {overload(@metrics).overloaded_count}
          <%= if overload(@metrics).overloaded_count > 0 do %>
            (max {:erlang.float_to_binary(overload(@metrics).max_loading_pct * 1.0, decimals: 0)}%)
          <% end %>
          <%= if overload(@metrics).unrated_count > 0 do %>
            <span class="metric-sub">{overload(@metrics).unrated_count} unrated</span>
          <% end %>
        </span>
      </div>
      <div :if={abs(mismatch_mw(@metrics)) > 1.0} class="metric">
        <span class="metric-label">Mismatch</span>
        <span class="metric-value freq-warning">{format_mw(mismatch_mw(@metrics))}</span>
      </div>
      <div class="metric metric-frequency">
        <span class="metric-label">Frequency</span>
        <span id="metric-frequency" class={"metric-value " <> freq_class(current_hz(@metrics))}>
          {:erlang.float_to_binary(current_hz(@metrics), decimals: 2)} Hz
          <span :if={nadir_hz(@metrics) < 59.995} class="metric-sub">
            nadir {:erlang.float_to_binary(nadir_hz(@metrics), decimals: 2)}
          </span>
        </span>
        <.freq_sparkline :if={sparkline(@metrics)} trace={sparkline(@metrics)} />
      </div>
      <div :if={agc(@metrics) != nil} class="metric">
        <span class="metric-label">AGC</span>
        <span
          id="metric-agc"
          class={"metric-value " <> if(agc(@metrics).saturated?, do: "freq-warning", else: "")}
        >
          {format_mw(agc(@metrics).dispatched_mw)}
          <span class="metric-sub">
            {format_mw(agc(@metrics).reserve_remaining_mw)} reserve{if agc(@metrics).saturated?,
              do: " — saturated"}
          </span>
        </span>
      </div>
      <div :if={ac_coverage(@metrics) != nil} class="metric">
        <span class="metric-label">AC layer</span>
        <span
          id="metric-ac-coverage"
          class="metric-value"
          title="Islands that reached an AC solution; the rest ran DC-only, where voltage relays are inactive."
        >
          {ac_coverage(@metrics).solved}/{ac_coverage(@metrics).total}
          <span class="metric-sub">islands</span>
        </span>
      </div>
      <div class="metric">
        <span class="metric-label">Islands</span>
        <span class="metric-value">{@metrics.islands}</span>
      </div>
      <div class="metric">
        <span class="metric-label">Tripped</span>
        <span
          id="metric-tripped"
          class={"metric-value " <> if(@metrics.tripped_count > 0, do: "text-red", else: "")}
        >
          {@metrics.tripped_count}
        </span>
      </div>
    </div>
    """
  end

  # Inline SVG, no charting dependency: the frequency trace is a polyline and
  # a nominal reference line, drawn in the panel's own type scale.
  attr :trace, :map, required: true

  defp freq_sparkline(assigns) do
    ~H"""
    <svg
      id="freq-sparkline"
      class="freq-spark"
      viewBox="0 0 120 28"
      preserveAspectRatio="none"
      role="img"
      aria-labelledby="freq-sparkline-title"
    >
      <title id="freq-sparkline-title">{@trace.label}</title>
      <line
        x1="0"
        x2="120"
        y1={@trace.nominal_y}
        y2={@trace.nominal_y}
        stroke="rgba(120,120,140,0.35)"
        stroke-width="1"
        stroke-dasharray="3,3"
      />
      <polyline
        points={@trace.points}
        fill="none"
        stroke={@trace.stroke}
        stroke-width="1.5"
        stroke-linejoin="round"
        stroke-linecap="round"
      />
    </svg>
    """
  end

  @spark_w 120
  @spark_h 28

  # Two points is the minimum that draws a line; one sample is not a trace.
  defp sparkline(metrics) do
    case Map.get(metrics, :freq_history) do
      history when is_list(history) and length(history) >= 2 -> build_spark(history)
      _ -> nil
    end
  end

  defp build_spark(history) do
    values = Enum.map(history, fn {_t, hz} -> hz * 1.0 end)

    # The band is anchored at nominal so a flat 60.00 Hz trace sits on the
    # reference line instead of being auto-scaled into a meaningless wiggle.
    lo = Enum.min(values) |> min(59.5)
    hi = Enum.max(values) |> max(60.05)
    span = max(hi - lo, 0.1)
    n = length(values)

    points =
      values
      |> Enum.with_index()
      |> Enum.map(fn {hz, i} ->
        x = if n > 1, do: i / (n - 1) * @spark_w, else: 0.0
        y = @spark_h - (hz - lo) / span * @spark_h
        "#{Float.round(x, 1)},#{Float.round(y, 1)}"
      end)
      |> Enum.join(" ")

    %{
      points: points,
      nominal_y: Float.round(@spark_h - (60.0 - lo) / span * @spark_h, 1),
      stroke: spark_stroke(Enum.min(values)),
      # UI-L16: the trace's accessible name. A polyline says nothing to a
      # screen reader, and the two numbers it is drawn to communicate -- where
      # the system is now and how far it dipped -- are exactly what the name
      # has to carry.
      label: spark_label(values)
    }
  end

  defp spark_label(values) do
    now = :erlang.float_to_binary(List.last(values), decimals: 2)
    low = :erlang.float_to_binary(Enum.min(values), decimals: 2)
    "Frequency trace over #{length(values)} steps: now #{now} Hz, lowest #{low} Hz"
  end

  defp spark_stroke(min_hz) when min_hz >= 59.95, do: "#2ecc71"
  defp spark_stroke(min_hz) when min_hz >= 59.5, do: "#f5a623"
  defp spark_stroke(_min_hz), do: "#e74c3c"

  defp current_hz(metrics), do: (Map.get(metrics, :frequency_hz) || 60.0) * 1.0

  defp nadir_hz(metrics) do
    (Map.get(metrics, :frequency_nadir_hz) || current_hz(metrics)) * 1.0
  end

  # One row for the whole system: sum what secondary control dispatched and
  # what it has left across the islands that have a controller. Islands
  # without one contribute nothing rather than a zero.
  defp agc(metrics) do
    case Map.get(metrics, :agc) do
      [_ | _] = summaries ->
        Enum.reduce(
          summaries,
          %{dispatched_mw: 0.0, reserve_remaining_mw: 0.0, saturated?: false},
          fn s, acc ->
            %{
              dispatched_mw: acc.dispatched_mw + num(s[:dispatched_mw]),
              reserve_remaining_mw: acc.reserve_remaining_mw + num(s[:reserve_remaining_mw]),
              saturated?: acc.saturated? or s[:saturated?] == true
            }
          end
        )

      _ ->
        nil
    end
  end

  # islands_ac counts island-SOLVES that carried a voltage layer; the rest of
  # the solves ran DC-only. Diverged and skipped attempts are already inside
  # islands_dc_only, so the denominator is the two of them.
  defp ac_coverage(metrics) do
    case Map.get(metrics, :voltage_layer) do
      %{islands_ac: ac, islands_dc_only: dc}
      when is_integer(ac) and is_integer(dc) and ac + dc > 0 ->
        %{solved: ac, total: ac + dc}

      _ ->
        nil
    end
  end

  defp btm_mw(metrics), do: num(Map.get(metrics, :btm_tripped_mw))

  defp btm_breakdown(metrics) do
    case Map.get(metrics, :btm_trip_breakdown) do
      %{} = b -> b
      _ -> nil
    end
  end

  defp btm_split_text(metrics) do
    b = btm_breakdown(metrics)
    "#{format_mw(num(b[:frequency_mw]))} freq / #{format_mw(num(b[:voltage_mw]))} volt"
  end

  # Served load: cascade balance when present, otherwise the solver total.
  defp served_mw(metrics) do
    case Map.get(metrics, :served_mw, 0.0) do
      v when is_number(v) and v > 0.0 -> v
      _ -> Map.get(metrics, :total_load_mw) || 0.0
    end
  end

  defp demand_mw(metrics), do: Map.get(metrics, :demand_mw) || 0.0

  defp shed_total_mw(metrics) do
    (Map.get(metrics, :shed_mw) || 0.0) + (Map.get(metrics, :blackout_mw) || 0.0)
  end

  defp mismatch_mw(metrics) do
    case Map.get(metrics, :mismatch_mw) do
      v when is_number(v) -> v
      _ -> 0.0
    end
  end

  defp num(v) when is_number(v), do: v * 1.0
  defp num(_), do: 0.0

  @empty_overload %{
    overloaded_count: 0,
    max_loading_pct: 0.0,
    overload_mw: 0.0,
    monitored_count: 0,
    unrated_count: 0
  }

  defp overload(metrics), do: Map.get(metrics, :overload) || @empty_overload

  defp format_mw(nil), do: "—"

  defp format_mw(mw) when mw >= 1000 or mw <= -1000,
    do: "#{:erlang.float_to_binary(mw / 1000.0, decimals: 1)} GW"

  defp format_mw(mw), do: "#{:erlang.float_to_binary(mw * 1.0, decimals: 0)} MW"

  defp freq_class(hz) when hz >= 59.95, do: "freq-normal"
  defp freq_class(hz) when hz >= 59.5, do: "freq-warning"
  defp freq_class(_), do: "freq-critical"
end
