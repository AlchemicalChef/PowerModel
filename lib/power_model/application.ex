defmodule PowerModel.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        PowerModel.Repo,
        PowerModelWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:power_model, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: PowerModel.PubSub},
        {Registry, keys: :unique, name: PowerModel.SimulationRegistry},
        {DynamicSupervisor, name: PowerModel.SimulationSupervisor, strategy: :one_for_one},
        {Task.Supervisor, name: PowerModel.TaskSupervisor},
        PowerModelWeb.Endpoint
      ]

    opts = [strategy: :one_for_one, name: PowerModel.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    PowerModelWeb.Endpoint.config_change(changed, removed)
    :ok
  end

end
