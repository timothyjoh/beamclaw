defmodule BeamClaw.Gateway.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BeamClaw.Gateway.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", BeamClaw.Gateway do
    pipe_through :browser
    live "/", DashboardLive
  end

  scope "/v1", BeamClaw.Gateway do
    pipe_through :api
    post "/chat/completions", ChatController, :completions
  end

  scope "/", BeamClaw.Gateway do
    pipe_through :api
    get "/health", HealthController, :index
  end
end
