import Config

# Test environment configuration
config :logger, level: :warning

config :beamclaw, BeamClaw.Gateway.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix-security-requirements-ok-test",
  server: false
