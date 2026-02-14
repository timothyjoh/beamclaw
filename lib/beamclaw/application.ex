defmodule BeamClaw.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
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

      # Phoenix endpoint (must be last)
      BeamClaw.Gateway.Endpoint
    ]

    opts = [strategy: :one_for_one, name: BeamClaw.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
