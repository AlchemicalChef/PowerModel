import Config

config :power_model, PowerModel.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "power_model_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :power_model, PowerModelWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "aa4sr/J61zCK2kAEXFB9LPebkmqlCk6IdssoIyM+6E1NqVOiA28oFE6qCobfChC1",
  server: false

config :power_model, PowerModel.Mailer, adapter: Swoosh.Adapters.Test

config :swoosh, :api_client, false

config :power_model, skip_repo: true

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :phoenix,
  sort_verified_routes_query_params: true
