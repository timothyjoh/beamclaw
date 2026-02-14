import Config

# Production environment configuration
config :logger, level: :info

# Cluster configuration - Kubernetes DNS strategy for production
config :beamclaw, :cluster_topologies, [
  k8s: [
    strategy: Cluster.Strategy.Kubernetes.DNS,
    config: [
      service: "beamclaw-headless",
      application_name: "beamclaw"
    ]
  ]
]
