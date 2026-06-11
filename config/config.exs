import Config

config :power_model,
  ecto_repos: [PowerModel.Repo],
  generators: [timestamp_type: :utc_datetime]

config :power_model, PowerModel.Repo, types: PowerModel.PostgresTypes

config :power_model, PowerModelWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PowerModelWeb.ErrorHTML, json: PowerModelWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PowerModel.PubSub,
  live_view: [signing_salt: "xlQIujSU"]

config :power_model, PowerModel.Mailer, adapter: Swoosh.Adapters.Local

config :esbuild,
  version: "0.25.4",
  power_model: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.1.12",
  power_model: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
