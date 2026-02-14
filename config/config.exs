import Config

# General application configuration
config :beamclaw,
  default_model: "claude-sonnet-4-5-20250929",
  default_max_tokens: 8192

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :session_id]

# Import environment specific config
import_config "#{config_env()}.exs"
