defmodule BeamClaw.Gateway.Endpoint do
  use Phoenix.Endpoint, otp_app: :beamclaw

  @session_options [
    store: :cookie,
    key: "_beamclaw_key",
    signing_salt: "beamclaw_salt",
    same_site: "Lax"
  ]

  socket "/ws", BeamClaw.Gateway.UserSocket,
    websocket: true,
    longpoll: false

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :beamclaw,
    gzip: false,
    only: ~w(favicon.ico robots.txt)

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug BeamClaw.Gateway.Router
end
