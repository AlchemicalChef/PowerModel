defmodule PowerModelWeb.GridLive.FailureControls do
  @moduledoc """
  Failure injection controls, and the N-1 contingency screening panel.

  ## What the N-1 numbers mean (UIW-2 / UIW-3)

  Until now this panel showed the count of components the *user* had already
  tripped and called them "contingencies with violations" (REVIEW UI-M15). It
  now renders a real `PowerModel.Analysis.ContingencyScreening` sweep, and
  three properties of that result decide how it must be displayed:

    * **`mw_at_risk` does not mean the same thing in both categories.** For a
      `:thermal` entry it is the overload megawatts the outage *added*; for an
      `:island_split` it is the generation/load shortfall the split strands.
      Adding them, or captioning them the same way, would be a unit error.

    * **`max_loading_pct` is `nil` for an island split** -- there is no flow
      update for an outage that disconnects the network, so there is no
      loading to report. It renders as an em-dash, never as 0%.

    * **The base case already has overloads in it.** Every ranked metric is
      incremental against that base, so the base row is pinned above the list:
      without it a user reads pre-existing problems as contingency-caused.

  The whole sweep aborts on any solve failure and returns no partial results
  (`ContingencyScreening.screen/2`), so the error state here is whole-screen
  by design -- there is no half-list to show.

  Results are also **advisory the moment the injection vector changes**: LODF
  sensitivities are a linearisation about the operating point they were
  computed at, and any trip, redispatch or hour change invalidates them. The
  parent flips `stale` and the banner says so.
  """

  use PowerModelWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="failure-controls">
      <h4>Failure Injection</h4>

      <div class="control-group">
        <label class="control-label">Mode</label>
        <div class="mode-buttons">
          <button
            id="failure-mode-single"
            class={"mode-btn " <> if(@mode == :single, do: "active", else: "")}
            phx-click="set_failure_mode"
            phx-value-mode="single"
            phx-target={@myself}
          >
            Single
          </button>
          <button
            id="failure-mode-n1"
            class={"mode-btn " <> if(@mode == :n1, do: "active", else: "")}
            phx-click="set_failure_mode"
            phx-value-mode="n1"
            phx-target={@myself}
          >
            N-1 Scan
          </button>
        </div>
      </div>

      <%= if @mode == :single do %>
        <p class="control-hint">
          Click any line or generator on the map, then use the Info Panel to inject a failure.
        </p>
      <% else %>
        <div class="control-group">
          <label class="control-label">Contingency Screening</label>
          <button
            id="run-n1-screen-btn"
            phx-click="run_n1_screening"
            class="action-btn"
            disabled={@screening}
          >
            {if @screening, do: "Scanning...", else: "Run N-1 Screen"}
          </button>
          <p :if={@screening and @hint} class="control-hint n1-hint" id="n1-screen-hint">{@hint}</p>
        </div>

        <%= if @screen_error do %>
          <div class="violation-summary" id="n1-screen-error">
            <span class="violation-text">Screening failed — run again</span>
          </div>
        <% end %>

        <%= if @screen do %>
          <div class="n1-result" id="n1-result">
            <div :if={@stale} class="n1-stale" id="n1-stale-banner">
              Advisory — the network changed since this screen. Re-run.
            </div>

            <div class="n1-summary" id="n1-summary">
              <div class="n1-summary-cell">
                <span class="n1-summary-count text-red">{@screen.summary.thermal}</span>
                <span class="n1-summary-label">thermal</span>
              </div>
              <div class="n1-summary-cell">
                <span class="n1-summary-count n1-split">{@screen.summary.island_splits}</span>
                <span class="n1-summary-label">splits</span>
              </div>
              <div class="n1-summary-cell">
                <span class="n1-summary-count n1-clean">{@screen.summary.clean}</span>
                <span class="n1-summary-label">clean</span>
              </div>
            </div>

            <%!-- Pinned base row: every ranked metric above is INCREMENTAL
                  against this, so it has to be visible or pre-existing
                  overloads read as contingency-caused. --%>
            <div class="n1-base" id="n1-base">
              {@screen.base.overloaded} of {@screen.summary.screened} branches over rating
              pre-contingency
            </div>

            <%!-- LODF refuses a disconnected graph outright, so a session
                  that has islanded part of its network gets the largest
                  island screened and is told how much that was. --%>
            <div
              :if={@screen.scope.buses_screened < @screen.scope.buses_total}
              class="n1-base"
              id="n1-scope"
            >
              Screened the largest island: {format_int(@screen.scope.buses_screened)} of {format_int(
                @screen.scope.buses_total
              )} buses ({@screen.scope.islands} islands in scope)
            </div>

            <div class="n1-ranked">
              <div
                :for={entry <- @screen.ranked}
                class={"n1-entry " <> category_class(entry.category)}
              >
                <button
                  class="n1-entry-branch"
                  phx-click="select_component"
                  phx-value-type={component_type(entry.branch)}
                  phx-value-id={branch_id(entry.branch)}
                >
                  {branch_label(entry.branch)}
                </button>
                <div class="n1-entry-metrics">
                  <span class="n1-entry-mw">{format_mw(entry.mw_at_risk)}</span>
                  <span class="n1-entry-caption">{risk_caption(entry.category)}</span>
                </div>
                <div class="n1-entry-loading">
                  {loading_text(entry.max_loading_pct)}
                </div>
              </div>
            </div>

            <div class="n1-footnote">
              DC LODF screen, exact for a branch outage — no redispatch, no post-split
              re-solve. {format_ms(@screen.summary.elapsed_ms)}
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  def mount(socket), do: {:ok, assign(socket, :mode, :single)}

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  def handle_event("set_failure_mode", %{"mode" => mode}, socket) do
    mode = if mode in ["single", "n1"], do: String.to_existing_atom(mode), else: :single
    {:noreply, assign(socket, :mode, mode)}
  end

  # An island split has no post-outage flow to report a loading for; a zero
  # would read as "nothing was loaded", which is the opposite of the truth.
  defp loading_text(nil), do: "—"

  defp loading_text(pct) when is_number(pct),
    do: "#{:erlang.float_to_binary(pct * 1.0, decimals: 0)}%"

  defp loading_text(_), do: "—"

  # The two categories measure different megawatts. Never merge the captions.
  defp risk_caption(:island_split), do: "islanded shortfall MW"
  defp risk_caption(:thermal), do: "overload MW added"
  defp risk_caption(_), do: "MW at risk"

  defp category_class(:island_split), do: "n1-entry-split"
  defp category_class(:thermal), do: "n1-entry-thermal"
  defp category_class(_), do: ""

  defp branch_label({:line, id}), do: "Line #{id}"
  defp branch_label({:transformer, id}), do: "Xfmr #{id}"
  defp branch_label(other), do: inspect(other)

  defp component_type({:line, _id}), do: "transmission_line"
  defp component_type({:transformer, _id}), do: "transformer"
  defp component_type(_), do: ""

  defp branch_id({_kind, id}), do: id
  defp branch_id(_), do: ""

  defp format_mw(mw) when is_number(mw) and (mw >= 1000 or mw <= -1000),
    do: "#{:erlang.float_to_binary(mw / 1000.0, decimals: 1)} GW"

  defp format_mw(mw) when is_number(mw),
    do: "#{:erlang.float_to_binary(mw * 1.0, decimals: 0)} MW"

  defp format_mw(_), do: "—"

  defp format_ms(ms) when is_number(ms) and ms >= 1000,
    do: "#{:erlang.float_to_binary(ms / 1000.0, decimals: 1)} s"

  defp format_ms(ms) when is_number(ms), do: "#{round(ms)} ms"
  defp format_ms(_), do: ""

  defp format_int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_int(n), do: to_string(n)
end
