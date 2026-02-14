import Config

# Runtime configuration (loaded at runtime, can read env vars)

if config_env() == :prod do
  # In production, read secrets from environment variables
  if api_key = System.get_env("ANTHROPIC_API_KEY") do
    config :beamclaw, anthropic_api_key: api_key
  end

  if data_dir = System.get_env("BEAMCLAW_DATA_DIR") do
    config :beamclaw, data_dir: data_dir
  end

  # Phoenix endpoint production configuration
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE not set"

  config :beamclaw, BeamClaw.Gateway.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4000")],
    secret_key_base: secret_key_base
end
