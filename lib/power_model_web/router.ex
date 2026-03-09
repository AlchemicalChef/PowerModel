defmodule PowerModelWeb.Router do
  use PowerModelWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PowerModelWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PowerModelWeb do
    pipe_through :browser

    live "/", GridLive.Index, :index
    live "/grid", GridLive.Index, :index
    get "/legacy", PageController, :home
  end

  if Application.compile_env(:power_model, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PowerModelWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
