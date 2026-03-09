defmodule PowerModelWeb.GridLive.FailureControls do
  use PowerModelWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="failure-controls">
      <h4>Failure Injection</h4>

      <div class="control-group">
        <label class="control-label">Mode</label>
        <div class="mode-buttons">
          <button
            class={"mode-btn " <> if(@mode == :single, do: "active", else: "")}
            phx-click="set_failure_mode"
            phx-value-mode="single"
            phx-target={@myself}
          >
            Single
          </button>
          <button
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
        <p class="control-hint">Click any line or generator on the map, then use the Info Panel to inject a failure.</p>
      <% else %>
        <div class="control-group">
          <label class="control-label">Contingency Screening</label>
          <button
            phx-click="run_n1_screening"
            phx-target={@myself}
            class="action-btn"
            disabled={@screening}
          >
            <%= if @screening, do: "Scanning...", else: "Run N-1 Screen" %>
          </button>
        </div>

        <%= if @violations > 0 do %>
          <div class="violation-summary">
            <span class="violation-count"><%= @violations %></span>
            <span class="violation-text">contingencies with violations</span>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  def mount(socket) do
    {:ok, assign(socket, mode: :single, screening: false, violations: 0)}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  def handle_event("set_failure_mode", %{"mode" => mode}, socket) do
    mode = if mode in ["single", "n1"], do: String.to_existing_atom(mode), else: :single
    {:noreply, assign(socket, :mode, mode)}
  end

  def handle_event("run_n1_screening", _params, socket) do
    send(self(), :run_n1_screening)
    {:noreply, assign(socket, :screening, true)}
  end
end
