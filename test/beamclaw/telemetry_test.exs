defmodule BeamClaw.TelemetryTest do
  use ExUnit.Case, async: true

  alias BeamClaw.Telemetry

  setup do
    # Attach a test handler for each test
    test_pid = self()
    handler_id = "test-handler-#{:erlang.unique_integer()}"

    :telemetry.attach_many(
      handler_id,
      [
        [:beamclaw, :session, :start],
        [:beamclaw, :session, :stop],
        [:beamclaw, :provider, :request, :start],
        [:beamclaw, :provider, :request, :stop],
        [:beamclaw, :provider, :request, :exception],
        [:beamclaw, :tool, :execute, :start],
        [:beamclaw, :tool, :execute, :stop],
        [:beamclaw, :tool, :execute, :exception],
        [:beamclaw, :cron, :job, :start],
        [:beamclaw, :cron, :job, :stop],
        [:beamclaw, :cron, :job, :exception],
        [:beamclaw, :tenant, :create],
        [:beamclaw, :tenant, :delete]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  describe "session events" do
    test "emit_session_start/1 emits correct event" do
      metadata = %{session_key: "agent:test:main", agent_id: "test", session_id: "main"}
      Telemetry.emit_session_start(metadata)

      assert_receive {:telemetry_event, [:beamclaw, :session, :start], measurements, ^metadata}
      assert Map.has_key?(measurements, :system_time)
    end

    test "emit_session_stop/1 emits correct event" do
      metadata = %{
        session_key: "agent:test:main",
        agent_id: "test",
        session_id: "main",
        duration: 1_000_000
      }

      Telemetry.emit_session_stop(metadata)

      assert_receive {:telemetry_event, [:beamclaw, :session, :stop], measurements,
                      received_metadata}

      assert measurements.duration == 1_000_000
      assert received_metadata.session_key == "agent:test:main"
    end
  end

  describe "provider events" do
    test "emit_provider_request_start/1 emits correct event" do
      metadata = %{model: "claude-3-5-sonnet-20241022", max_tokens: 1024}
      Telemetry.emit_provider_request_start(metadata)

      assert_receive {:telemetry_event, [:beamclaw, :provider, :request, :start], measurements,
                      ^metadata}

      assert Map.has_key?(measurements, :system_time)
    end

    test "emit_provider_request_stop/2 emits correct event" do
      measurements = %{duration: 500_000}
      metadata = %{model: "claude-3-5-sonnet-20241022"}
      Telemetry.emit_provider_request_stop(measurements, metadata)

      assert_receive {:telemetry_event, [:beamclaw, :provider, :request, :stop],
                      ^measurements, ^metadata}
    end

    test "emit_provider_request_exception/2 emits correct event" do
      measurements = %{duration: 100_000}
      metadata = %{model: "claude-3-5-sonnet-20241022", error: :timeout}
      Telemetry.emit_provider_request_exception(measurements, metadata)

      assert_receive {:telemetry_event, [:beamclaw, :provider, :request, :exception],
                      ^measurements, ^metadata}
    end
  end

  describe "tool events" do
    test "emit_tool_execute_start/1 emits correct event" do
      metadata = %{command: "echo hello", security_mode: :gateway}
      Telemetry.emit_tool_execute_start(metadata)

      assert_receive {:telemetry_event, [:beamclaw, :tool, :execute, :start], measurements,
                      ^metadata}

      assert Map.has_key?(measurements, :system_time)
    end

    test "emit_tool_execute_stop/2 emits correct event" do
      measurements = %{duration: 50_000}
      metadata = %{command: "echo hello", exit_code: 0}
      Telemetry.emit_tool_execute_stop(measurements, metadata)

      assert_receive {:telemetry_event, [:beamclaw, :tool, :execute, :stop], ^measurements,
                      ^metadata}
    end

    test "emit_tool_execute_exception/2 emits correct event" do
      measurements = %{duration: 10_000}
      metadata = %{command: "false", exit_code: 1}
      Telemetry.emit_tool_execute_exception(measurements, metadata)

      assert_receive {:telemetry_event, [:beamclaw, :tool, :execute, :exception],
                      ^measurements, ^metadata}
    end
  end

  describe "cron events" do
    test "emit_cron_job_start/1 emits correct event" do
      metadata = %{agent_id: "test", job_id: "job1", job_type: :main}
      Telemetry.emit_cron_job_start(metadata)

      assert_receive {:telemetry_event, [:beamclaw, :cron, :job, :start], measurements,
                      ^metadata}

      assert Map.has_key?(measurements, :system_time)
    end

    test "emit_cron_job_stop/2 emits correct event" do
      measurements = %{duration: 200_000}
      metadata = %{agent_id: "test", job_id: "job1", job_type: :isolated}
      Telemetry.emit_cron_job_stop(measurements, metadata)

      assert_receive {:telemetry_event, [:beamclaw, :cron, :job, :stop], ^measurements,
                      ^metadata}
    end

    test "emit_cron_job_exception/2 emits correct event" do
      measurements = %{duration: 5_000}

      metadata = %{
        agent_id: "test",
        job_id: "job1",
        job_type: :main,
        error: "session not found"
      }

      Telemetry.emit_cron_job_exception(measurements, metadata)

      assert_receive {:telemetry_event, [:beamclaw, :cron, :job, :exception], ^measurements,
                      ^metadata}
    end
  end

  describe "tenant events" do
    test "emit_tenant_create/1 emits correct event" do
      metadata = %{tenant_id: "tenant1"}
      Telemetry.emit_tenant_create(metadata)

      assert_receive {:telemetry_event, [:beamclaw, :tenant, :create], measurements,
                      ^metadata}

      assert measurements.count == 1
    end

    test "emit_tenant_delete/1 emits correct event" do
      metadata = %{tenant_id: "tenant2"}
      Telemetry.emit_tenant_delete(metadata)

      assert_receive {:telemetry_event, [:beamclaw, :tenant, :delete], measurements,
                      ^metadata}

      assert measurements.count == 1
    end
  end

  describe "metrics/0" do
    test "returns a list of telemetry metrics" do
      metrics = Telemetry.metrics()

      assert is_list(metrics)
      assert length(metrics) > 0

      # Verify we have metrics for all major categories
      metric_names = Enum.map(metrics, & &1.event_name)

      assert [:beamclaw, :session, :start] in metric_names
      assert [:beamclaw, :provider, :request, :stop] in metric_names
      assert [:beamclaw, :tool, :execute, :stop] in metric_names
      assert [:beamclaw, :cron, :job, :stop] in metric_names
      assert [:beamclaw, :tenant, :create] in metric_names
    end
  end
end
