defmodule PowerModel.Repo do
  use Ecto.Repo,
    otp_app: :power_model,
    adapter: Ecto.Adapters.Postgres
end
