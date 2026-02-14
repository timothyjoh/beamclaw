import Config

# General application configuration
config :beamclaw,
  default_model: "claude-sonnet-4-5-20250929",
  default_max_tokens: 8192

# Phoenix endpoint configuration
config :beamclaw, BeamClaw.Gateway.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: BeamClaw.Gateway.ErrorJSON], layout: false],
  pubsub_server: BeamClaw.PubSub,
  live_view: [signing_salt: "beamclaw_lv"]

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Import environment specific config
import_config "#{config_env()}.exs"
