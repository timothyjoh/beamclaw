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
end
