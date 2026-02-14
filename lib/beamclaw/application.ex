defmodule BeamClaw.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Initialize ETS tables owned by the application master process.
    # These persist for the lifetime of the application.
    BeamClaw.Tool.Approval.init()
    BeamClaw.Tool.Registry.init()

    # Determine cluster children based on configuration
    cluster_children =
      case Application.get_env(:beamclaw, :cluster_topologies) do
        topologies when is_list(topologies) and topologies != [] ->
          [{Cluster.Supervisor, [topologies, [name: BeamClaw.ClusterSupervisor]]}]

        _ ->
          []
      end

    children = [
      # Process registry for {:session, id}, {:channel, id}, {:cron, agent_id}
      {Registry, keys: :unique, name: BeamClaw.Registry},

      # HTTP/2 connection pools for provider APIs
      {Finch,
       name: BeamClaw.Finch,
       pools: %{
         "https://api.anthropic.com" => [size: 10, count: 1, protocols: [:http2]]
       }},

      # PubSub for WebSocket broadcasts
      {Phoenix.PubSub, name: BeamClaw.PubSub},

      # :pg scope for distributed process groups
      %{id: :pg, start: {:pg, :start_link, [:beamclaw]}}
    ] ++ cluster_children ++ [
      # Runtime configuration GenServer
      BeamClaw.Config,

      # Background process tracking for Tool.Exec
      BeamClaw.BackgroundProcessRegistry,

      # Task supervisor for tool execution
      {Task.Supervisor, name: BeamClaw.ToolSupervisor},

      # DynamicSupervisor for session GenServers
      {DynamicSupervisor, name: BeamClaw.SessionSupervisor, strategy: :one_for_one},

      # DynamicSupervisor for channel GenServers
      {DynamicSupervisor, name: BeamClaw.ChannelSupervisor, strategy: :one_for_one},

      # DynamicSupervisor for cron workers
      {DynamicSupervisor, name: BeamClaw.CronSupervisor, strategy: :one_for_one},

      # DynamicSupervisor for tenant supervisors (multi-tenant support)
      {DynamicSupervisor, name: BeamClaw.TenantSupervisor, strategy: :one_for_one},

      # Tenant lifecycle manager
      BeamClaw.Tenant.Manager,

      # Telemetry supervisor
      BeamClaw.Telemetry,

      # Phoenix endpoint (must be last)
      BeamClaw.Gateway.Endpoint
    ]

    opts = [strategy: :one_for_one, name: BeamClaw.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
