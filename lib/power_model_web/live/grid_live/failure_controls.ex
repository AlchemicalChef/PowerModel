defmodule PowerModelWeb.GridLive.FailureControls do
  use PowerModelWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="failure-controls" id="failure-controls-panel">
      <h4>Failure Injection</h4>

      <div class="control-group">
        <label class="control-label">Mode</label>
        <div class="mode-buttons">
          <button
            id="failure-mode-single-btn"
            class={"mode-btn " <> if(@mode == :single, do: "active", else: "")}
            phx-click="set_failure_mode"
            phx-value-mode="single"
            phx-target={@myself}
          >
            Single
          </button>
          <button
            id="failure-mode-n1-btn"
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

          <form id="screening-config-form" phx-change="update_screening_options" phx-target={@myself}>
            <div class="screening-config-grid">
              <label class="screening-config-label">
                <span>K Max</span>
                <select name="screening[k_max]" class="screening-input">
                  <%= for k <- 1..4 do %>
                    <option value={k} selected={@screening_options.k_max == k}>
                      N-{k}
                    </option>
                  <% end %>
                </select>
              </label>

              <label class="screening-config-label">
                <span>Samples</span>
                <input
                  class="screening-input"
                  type="number"
                  min="100"
                  max="50000"
                  step="100"
                  name="screening[sample_size]"
                  value={@screening_options.sample_size}
                />
              </label>

              <label class="screening-config-label">
                <span>Top K</span>
                <input
                  class="screening-input"
                  type="number"
                  min="1"
                  max="100"
                  step="1"
                  name="screening[top_k]"
                  value={@screening_options.top_k}
                />
              </label>
            </div>
          </form>

          <button
            id="run-n1-screen-btn"
            phx-click="run_n1_screening"
            phx-target={@myself}
            class="action-btn"
            disabled={@screening}
          >
            {if @screening, do: "Scanning...", else: "Run N-1 Screen"}
          </button>
        </div>

        <%= if @violations > 0 do %>
          <div class="violation-summary">
            <span class="violation-count">{@violations}</span>
            <span class="violation-text">contingencies with violations</span>
          </div>
        <% end %>

        <%= if @screening_summary && @screening_summary.sampled_count > 0 do %>
          <div class="screening-meta">
            <span>Sampled {@screening_summary.sampled_count}</span>
            <%= if is_number(@screening_summary[:worst_loading_pct]) do %>
              <span>Worst {fmt_float(@screening_summary.worst_loading_pct, 1)}%</span>
            <% end %>
            <%= if is_number(@screening_summary[:worst_score]) do %>
              <span>Score {fmt_float(@screening_summary.worst_score, 1)}</span>
            <% end %>
          </div>
        <% end %>

        <%= if @screening_results != [] do %>
          <div class="screening-list">
            <%= for result <- @screening_results do %>
              <div class={"screening-item " <> if(result.severe, do: "severe", else: "")}>
                <div class="screening-item-header">
                  <span>{result.label}</span>
                  <span>{fmt_float(result.max_loading_pct, 1)}%</span>
                </div>
                <div class="screening-item-metrics">
                  <span>OL {result.overloaded_count}</span>
                  <span>Risk {fmt_float(result.mw_at_risk, 1)} MW</span>
                  <%= if result.island_split do %>
                    <span>Island split</span>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      <% end %>

      <div class="control-group model-options-group">
        <label class="control-label">Model Options</label>

        <%= for {key, label} <- model_option_labels() do %>
          <label class="toggle-row">
            <input
              id={"model-option-#{Atom.to_string(key)}"}
              type="checkbox"
              checked={Map.get(@model_options, key, false)}
              phx-click="set_model_option"
              phx-value-option={Atom.to_string(key)}
              phx-value-enabled={if(Map.get(@model_options, key, false), do: "false", else: "true")}
            />
            <span class="toggle-text">{label}</span>
          </label>
        <% end %>
      </div>

      <div class="control-group validation-group">
        <label class="control-label">Validation Suite</label>

        <form id="validation-case-select-form" phx-change="select_validation_case">
          <select id="validation-case-select" name="case_id" class="validation-select">
            <%= for validation_case <- @validation_cases do %>
              <option
                value={validation_case.id}
                selected={validation_case.id == @selected_validation_case_id}
              >
                {validation_case.id} - {validation_case.description}
              </option>
            <% end %>
          </select>
        </form>

        <div class="validation-actions">
          <button
            id="run-validation-case-btn"
            phx-click="run_validation_case"
            class="action-btn validation-btn"
            disabled={@validation_running or is_nil(@selected_validation_case_id)}
          >
            {if @validation_running, do: "Running...", else: "Run Case"}
          </button>
          <button
            id="run-validation-suite-btn"
            phx-click="run_validation_suite"
            class="action-btn validation-btn"
            disabled={@validation_running}
          >
            Run Suite
          </button>
        </div>

        <%= if @validation_report do %>
          <div class="validation-report">
            <div class="validation-report-header">
              <span>Report {Map.get(@validation_report, :generated_at, "")}</span>
              <button
                id="clear-validation-report-btn"
                phx-click="clear_validation_report"
                class="validation-clear-btn"
                type="button"
              >
                Clear
              </button>
            </div>

            <%= if @validation_report.mode == :single and @validation_report[:case] do %>
              <% case_result = @validation_report.case %>
              <div class="validation-summary">
                <span class={"validation-badge " <> if(case_result.passed, do: "ok", else: "fail")}>
                  {if case_result.passed, do: "PASS", else: "FAIL"}
                </span>
                <span class="validation-score">{case_result.score}</span>
              </div>
              <p class="validation-case-id">{case_result.id}</p>
              <p class="validation-case-desc">{case_result.description}</p>
              <div class="validation-metrics">
                <span>fmin {fmt_float(case_result.min_frequency_hz, 2)} Hz</span>
                <span>UFLS {fmt_float(case_result.ufls_shed_mw, 1)} MW</span>
                <%= if is_number(case_result[:voltage_margin_mw]) do %>
                  <span>CPF {fmt_float(case_result.voltage_margin_mw, 1)} MW</span>
                <% end %>
                <%= if is_boolean(case_result[:small_signal_stable]) do %>
                  <span>
                    Small Signal {if case_result.small_signal_stable, do: "Stable", else: "Unstable"}
                  </span>
                <% end %>
                <%= if is_integer(case_result[:stability_modes_count]) do %>
                  <span>Modes {case_result.stability_modes_count}</span>
                <% end %>
                <%= if is_integer(case_result[:transient_checks_run]) do %>
                  <span>
                    Transient {case_result.transient_checks_run} ({Map.get(
                      case_result,
                      :transient_unstable_checks,
                      0
                    )} unstable)
                  </span>
                <% end %>
                <%= if is_integer(case_result[:out_of_step_event_count]) do %>
                  <span>OOS {case_result.out_of_step_event_count}</span>
                <% end %>
                <span>THD {fmt_float(case_result.harmonics_worst_thd_pct, 2)}%</span>
              </div>
            <% end %>

            <%= if @validation_report.mode == :suite and @validation_report[:summary] do %>
              <% summary = @validation_report.summary %>
              <div class="validation-summary">
                <span class={"validation-badge " <> if(summary.all_passed, do: "ok", else: "fail")}>
                  {summary.passing_case_count}/{summary.case_count}
                </span>
                <span class="validation-score">Avg {summary.average_score}</span>
              </div>
              <div class="validation-suite-list">
                <%= for validation_case <- Enum.take(@validation_report.cases || [], 6) do %>
                  <div class="validation-suite-item">
                    <span>{validation_case.id}</span>
                    <span class={if(validation_case.passed, do: "ok-text", else: "fail-text")}>
                      {validation_case.score}
                    </span>
                  </div>
                <% end %>
              </div>
            <% end %>

            <%= if @validation_report.mode == :single_error do %>
              <p class="validation-error">
                Unable to run case <code>{Map.get(@validation_report, :case_id, "unknown")}</code>.
              </p>
            <% end %>
          </div>
        <% end %>
      </div>

      <%= if @analysis_results do %>
        <div class="control-group analysis-group">
          <label class="control-label">Post-Stabilization</label>
          <div class="analysis-grid">
            <span>Steps {Map.get(@analysis_results, :steps, 0)}</span>
            <span>Events {Map.get(@analysis_results, :total_events, 0)}</span>
            <%= if is_number(@analysis_results[:voltage_margin_mw]) do %>
              <span>CPF {fmt_float(@analysis_results.voltage_margin_mw, 1)} MW</span>
            <% end %>
            <%= if is_boolean(@analysis_results[:small_signal_stable]) do %>
              <span>
                Small Signal {if @analysis_results.small_signal_stable, do: "Stable", else: "Unstable"}
              </span>
            <% end %>
            <%= if is_integer(@analysis_results[:stability_modes_count]) do %>
              <span>Modes {@analysis_results.stability_modes_count}</span>
            <% end %>
            <%= if is_integer(@analysis_results[:critical_bus_id]) do %>
              <span>Critical Bus {@analysis_results.critical_bus_id}</span>
            <% end %>
            <%= if is_integer(@analysis_results[:transient_checks_run]) do %>
              <span>
                Transient Checks {@analysis_results.transient_checks_run} ({Map.get(
                  @analysis_results,
                  :transient_unstable_checks,
                  0
                )} unstable)
              </span>
            <% end %>
            <%= if is_integer(@analysis_results[:transient_failed_checks]) and
                      @analysis_results.transient_failed_checks > 0 do %>
              <span>Transient Failed {@analysis_results.transient_failed_checks}</span>
            <% end %>
            <%= if is_boolean(@analysis_results[:transient_last_stable]) do %>
              <span>
                Transient Last {if @analysis_results.transient_last_stable,
                  do: "Stable",
                  else: "Unstable"}
              </span>
            <% end %>
            <%= if is_integer(@analysis_results[:transient_last_oos_count]) do %>
              <span>Out-of-Step Trips {@analysis_results.transient_last_oos_count}</span>
            <% end %>
            <%= if is_number(@analysis_results[:transient_last_min_frequency_hz]) do %>
              <span>
                Transient fmin {fmt_float(@analysis_results.transient_last_min_frequency_hz, 2)} Hz
              </span>
            <% end %>
            <%= if is_number(@analysis_results[:transient_last_max_delta_deg]) do %>
              <span>
                Delta Spread {fmt_float(@analysis_results.transient_last_max_delta_deg, 1)} deg
              </span>
            <% end %>
            <%= if is_map(@analysis_results[:harmonics_worst_thd]) do %>
              <span>Worst THD {fmt_float(@analysis_results.harmonics_worst_thd.thd_pct, 2)}%</span>
            <% end %>
            <%= if is_integer(@analysis_results[:harmonics_violations]) do %>
              <span>THD Violations {@analysis_results.harmonics_violations}</span>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  def mount(socket) do
    {:ok, assign(socket, mode: :single, screening: false, violations: 0)}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign_new(:model_options, fn -> %{} end)
      |> assign_new(:analysis_results, fn -> nil end)
      |> assign_new(:validation_cases, fn -> [] end)
      |> assign_new(:selected_validation_case_id, fn -> nil end)
      |> assign_new(:validation_running, fn -> false end)
      |> assign_new(:validation_report, fn -> nil end)
      |> assign_new(:screening_summary, fn -> nil end)
      |> assign_new(:screening_results, fn -> [] end)
      |> assign_new(:screening_options, fn -> default_screening_options() end)
      |> assign(assigns)

    {:ok, socket}
  end

  def handle_event("set_failure_mode", %{"mode" => mode}, socket) do
    mode = if mode in ["single", "n1"], do: String.to_existing_atom(mode), else: :single
    {:noreply, assign(socket, :mode, mode)}
  end

  def handle_event("run_n1_screening", _params, socket) do
    send(self(), {:run_n1_screening, screening_opts(socket.assigns.screening_options)})
    {:noreply, assign(socket, :screening, true)}
  end

  def handle_event("update_screening_options", %{"screening" => params}, socket) do
    current = socket.assigns.screening_options

    updated = %{
      k_max: parse_bounded_int(Map.get(params, "k_max"), current.k_max, 1, 4),
      sample_size:
        parse_bounded_int(Map.get(params, "sample_size"), current.sample_size, 100, 50_000),
      top_k: parse_bounded_int(Map.get(params, "top_k"), current.top_k, 1, 100)
    }

    {:noreply, assign(socket, :screening_options, updated)}
  end

  def handle_event("update_screening_options", _params, socket) do
    {:noreply, socket}
  end

  defp model_option_labels do
    [
      {:use_ac, "AC Power Flow"},
      {:use_transient, "Transient Stability"},
      {:use_opf, "OPF Dispatch"},
      {:run_cpf, "Run CPF"},
      {:run_small_signal, "Small-Signal"},
      {:run_harmonics, "Cascade Harmonics"}
    ]
  end

  defp fmt_float(value, decimals) when is_number(value) do
    :erlang.float_to_binary(value * 1.0, decimals: decimals)
  end

  defp fmt_float(_value, _decimals), do: "0.0"

  defp default_screening_options do
    %{
      k_max: 1,
      sample_size: 2_500,
      top_k: 30
    }
  end

  defp screening_opts(options) do
    [
      k_range: 1..max(options.k_max, 1),
      sample_size: options.sample_size,
      top_k: options.top_k
    ]
  end

  defp parse_bounded_int(nil, fallback, _min, _max), do: fallback
  defp parse_bounded_int("", fallback, _min, _max), do: fallback

  defp parse_bounded_int(value, fallback, min, max) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n |> max(min) |> min(max)
      :error -> fallback
    end
  end
end
