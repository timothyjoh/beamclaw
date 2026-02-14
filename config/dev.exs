import Config

# Development environment configuration
config :logger, level: :debug

# Phoenix endpoint dev configuration
config :beamclaw, BeamClaw.Gateway.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: false,
  debug_errors: true,
  secret_key_base:
    "dev-only-secret-key-base-that-is-at-least-64-bytes-long-for-phoenix-security-requirements-ok",
  watchers: [],
  live_reload: [
    patterns: [
      ~r"lib/beamclaw/gateway/.*(ex|heex)$"
    ]
  ]

# Cluster configuration - Gossip strategy for local development
config :beamclaw, :cluster_topologies, [
  gossip: [
    strategy: Cluster.Strategy.Gossip
  ]
]
