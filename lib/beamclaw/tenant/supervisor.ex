defmodule BeamClaw.Tenant.Supervisor do
  @moduledoc """
  Per-tenant Supervisor that manages isolated supervision subtrees.

  Each tenant gets its own:
  - DynamicSupervisor for sessions
  - DynamicSupervisor for channels
  - DynamicSupervisor for cron workers
  - Task.Supervisor for tool execution

  These supervisors are registered in BeamClaw.Registry with keys:
  - {:tenant_sessions, tenant_id}
  - {:tenant_channels, tenant_id}
  - {:tenant_cron, tenant_id}
  - {:tenant_tools, tenant_id}
  """

  use Supervisor

  @doc """
  Starts a tenant supervisor for the given tenant.
  """
  def start_link(tenant) do
    Supervisor.start_link(__MODULE__, tenant,
      name: via_tuple({:tenant_supervisor, tenant.id})
    )
  end

  @impl true
  def init(tenant) do
    children = [
      # DynamicSupervisor for session GenServers
      {DynamicSupervisor,
       name: via_tuple({:tenant_sessions, tenant.id}), strategy: :one_for_one},

      # DynamicSupervisor for channel GenServers
      {DynamicSupervisor,
       name: via_tuple({:tenant_channels, tenant.id}), strategy: :one_for_one},

      # DynamicSupervisor for cron workers
      {DynamicSupervisor,
       name: via_tuple({:tenant_cron, tenant.id}), strategy: :one_for_one},

      # Task.Supervisor for tool execution
      {Task.Supervisor, name: via_tuple({:tenant_tools, tenant.id})}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns a via tuple for registering processes in BeamClaw.Registry.
  """
  def via_tuple(key) do
    {:via, Registry, {BeamClaw.Registry, key}}
  end

  @doc """
  Returns the PID of a tenant's session supervisor.
  """
  def session_supervisor(tenant_id) do
    case Registry.lookup(BeamClaw.Registry, {:tenant_sessions, tenant_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Returns the PID of a tenant's channel supervisor.
  """
  def channel_supervisor(tenant_id) do
    case Registry.lookup(BeamClaw.Registry, {:tenant_channels, tenant_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Returns the PID of a tenant's cron supervisor.
  """
  def cron_supervisor(tenant_id) do
    case Registry.lookup(BeamClaw.Registry, {:tenant_cron, tenant_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Returns the PID of a tenant's tool supervisor.
  """
  def tool_supervisor(tenant_id) do
    case Registry.lookup(BeamClaw.Registry, {:tenant_tools, tenant_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
