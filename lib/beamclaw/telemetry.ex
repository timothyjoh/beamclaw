defmodule BeamClaw.Telemetry do
  @moduledoc """
  Telemetry metrics and event definitions for BeamClaw.

  Provides telemetry instrumentation for sessions, provider calls, tool execution,
  and cron jobs. Also configures telemetry_poller for VM metrics.
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the list of metrics for LiveDashboard and other telemetry reporters.
  """
  def metrics do
    [
      # Session metrics
      counter("beamclaw.session.start.total"),
      counter("beamclaw.session.stop.total"),
      summary("beamclaw.session.stop.duration"),

      # Provider metrics
      counter("beamclaw.provider.request.start.total"),
      counter("beamclaw.provider.request.stop.total"),
      summary("beamclaw.provider.request.stop.duration"),
      counter("beamclaw.provider.request.exception.total"),

      # Tool metrics
      counter("beamclaw.tool.execute.start.total"),
      counter("beamclaw.tool.execute.stop.total"),
      summary("beamclaw.tool.execute.stop.duration"),
      counter("beamclaw.tool.execute.exception.total"),

      # Cron metrics
      counter("beamclaw.cron.job.start.total"),
      counter("beamclaw.cron.job.stop.total"),
      summary("beamclaw.cron.job.stop.duration"),
      counter("beamclaw.cron.job.exception.total"),

      # Tenant metrics
      counter("beamclaw.tenant.create.total"),
      counter("beamclaw.tenant.delete.total"),

      # VM metrics from poller
      summary("vm.memory.total", unit: :byte),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    []
  end

  # Helper functions for emitting events

  @doc "Emit session start event"
  def emit_session_start(metadata) do
    :telemetry.execute(
      [:beamclaw, :session, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc "Emit session stop event"
  def emit_session_stop(metadata) do
    :telemetry.execute(
      [:beamclaw, :session, :stop],
      %{duration: metadata[:duration] || 0},
      metadata
    )
  end

  @doc "Emit provider request start event"
  def emit_provider_request_start(metadata) do
    :telemetry.execute(
      [:beamclaw, :provider, :request, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc "Emit provider request stop event"
  def emit_provider_request_stop(measurements, metadata) do
    :telemetry.execute(
      [:beamclaw, :provider, :request, :stop],
      measurements,
      metadata
    )
  end

  @doc "Emit provider request exception event"
  def emit_provider_request_exception(measurements, metadata) do
    :telemetry.execute(
      [:beamclaw, :provider, :request, :exception],
      measurements,
      metadata
    )
  end

  @doc "Emit tool execute start event"
  def emit_tool_execute_start(metadata) do
    :telemetry.execute(
      [:beamclaw, :tool, :execute, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc "Emit tool execute stop event"
  def emit_tool_execute_stop(measurements, metadata) do
    :telemetry.execute(
      [:beamclaw, :tool, :execute, :stop],
      measurements,
      metadata
    )
  end

  @doc "Emit tool execute exception event"
  def emit_tool_execute_exception(measurements, metadata) do
    :telemetry.execute(
      [:beamclaw, :tool, :execute, :exception],
      measurements,
      metadata
    )
  end

  @doc "Emit cron job start event"
  def emit_cron_job_start(metadata) do
    :telemetry.execute(
      [:beamclaw, :cron, :job, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc "Emit cron job stop event"
  def emit_cron_job_stop(measurements, metadata) do
    :telemetry.execute(
      [:beamclaw, :cron, :job, :stop],
      measurements,
      metadata
    )
  end

  @doc "Emit cron job exception event"
  def emit_cron_job_exception(measurements, metadata) do
    :telemetry.execute(
      [:beamclaw, :cron, :job, :exception],
      measurements,
      metadata
    )
  end

  @doc "Emit tenant create event"
  def emit_tenant_create(metadata) do
    :telemetry.execute(
      [:beamclaw, :tenant, :create],
      %{count: 1},
      metadata
    )
  end

  @doc "Emit tenant delete event"
  def emit_tenant_delete(metadata) do
    :telemetry.execute(
      [:beamclaw, :tenant, :delete],
      %{count: 1},
      metadata
    )
  end
end
