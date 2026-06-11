defmodule PowerModel.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
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
        PowerModelWeb.Endpoint
      ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PowerModel.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PowerModelWeb.Endpoint.config_change(changed, removed)
    :ok
  end

end
