import Config

config :power_model, PowerModel.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "power_model_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :power_model, PowerModelWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "5e2/a5j0725l52zN15KP5D0DLmNE/Tzt8KLUUNtUd7v104gmYGTujy0b84JqVXZ5",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:power_model, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:power_model, ~w(--watch)]}
  ]

config :power_model, PowerModelWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      ~r"priv/gettext/.*\.po$"E,
      ~r"lib/power_model_web/router\.ex$"E,
      ~r"lib/power_model_web/(controllers|live|components)/.*\.(ex|heex)$"E
    ]
  ]

config :power_model, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

config :swoosh, :api_client, false
