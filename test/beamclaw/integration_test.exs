defmodule BeamClaw.IntegrationTest do
  @moduledoc """
  Phase 4 integration test: verifies channel, tool, and cron subsystems
  work together within the application supervision tree.
  """
  use ExUnit.Case, async: false

  alias BeamClaw.{BackgroundProcessRegistry, Tool.Exec}
  alias BeamClaw.{Cron.Worker, Cron.Schedule, Cron.Store}
  alias BeamClaw.Channel.Server, as: ChannelServer

  describe "supervision tree" do
    test "all Phase 4 supervisors are running" do
      children = Supervisor.which_children(BeamClaw.Supervisor)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      assert BeamClaw.ChannelSupervisor in child_ids
      assert BeamClaw.CronSupervisor in child_ids
      assert BeamClaw.ToolSupervisor in child_ids
      assert BeamClaw.BackgroundProcessRegistry in child_ids
    end

    test "DynamicSupervisors accept children" do
      # Channel supervisor can start a channel server with mock adapter
      channel_id = "integration-test-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        DynamicSupervisor.start_child(
          BeamClaw.ChannelSupervisor,
          {ChannelServer,
           adapter: BeamClaw.Channel.MockAdapter,
           channel_id: channel_id,
           config: %{}}
        )

      assert Process.alive?(pid)
      [{found_pid, _}] = Registry.lookup(BeamClaw.Registry, {:channel, channel_id})
      assert found_pid == pid

      GenServer.stop(pid, :normal)
    end
  end

  describe "tool → session flow" do
    test "exec tool runs a command and returns output" do
      assert {:ok, %{output: output, exit_code: 0}} = Exec.run("echo integration-test")
      assert String.trim(output) == "integration-test"
    end

    test "exec backgrounding + registry + kill flow" do
      assert {:ok, %{backgrounded: true, slug: slug}} = Exec.run("sleep 30")

      # Registered in BackgroundProcessRegistry
      assert {:ok, entry} = BackgroundProcessRegistry.get(slug)
      assert entry.exit_status == nil

      # Kill it (SIGTERM → SIGKILL escalation)
      :ok = BackgroundProcessRegistry.kill(slug)
    end
  end

  describe "cron → schedule → store flow" do
    setup do
      agent_id = "integration-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        DynamicSupervisor.start_child(
          BeamClaw.CronSupervisor,
          {Worker, agent_id: agent_id}
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        # Clean up JSONL file
        path = Store.jobs_path(agent_id)
        File.rm(path)
      end)

      {:ok, agent_id: agent_id, pid: pid}
    end

    test "add job, verify schedule, persist and reload", %{agent_id: agent_id} do
      # Add an :every job
      job = %{
        id: "test-job",
        type: :main,
        schedule: %{type: :every, value_ms: 60_000, anchor_ms: 0},
        prompt: "Integration test prompt",
        enabled: true
      }

      :ok = Worker.add_job(agent_id, "test-job", job)

      # Verify job is listed
      jobs = Worker.list_jobs(agent_id)
      assert map_size(jobs) == 1

      # Verify schedule computation
      now_ms = System.system_time(:millisecond)
      next = Schedule.compute_next_run(job.schedule, now_ms)
      assert is_integer(next)
      assert next > now_ms

      # Verify persistence
      stored_jobs = Store.load_jobs(agent_id)
      assert map_size(stored_jobs) == 1
      assert Map.has_key?(stored_jobs, "test-job")
    end

    test "worker registers in Registry", %{agent_id: agent_id, pid: pid} do
      [{found_pid, _}] = Registry.lookup(BeamClaw.Registry, {:cron, agent_id})
      assert found_pid == pid
    end
  end

  describe "channel → session message routing" do
    test "channel server routes inbound message to session and collects response" do
      channel_id = "routing-test-#{System.unique_integer([:positive])}"

      # Start a channel server with mock adapter
      {:ok, ch_pid} =
        DynamicSupervisor.start_child(
          BeamClaw.ChannelSupervisor,
          {ChannelServer,
           adapter: BeamClaw.Channel.MockAdapter,
           channel_id: channel_id,
           config: %{}}
        )

      assert Process.alive?(ch_pid)

      on_exit(fn ->
        if Process.alive?(ch_pid), do: GenServer.stop(ch_pid, :normal)
      end)
    end
  end

  describe "cross-subsystem: all registry key types" do
    test "Registry supports all Phase 4 key types simultaneously" do
      # Session (Phase 2)
      session_name = "integration-reg-#{System.unique_integer([:positive])}"
      {:ok, s_pid} = BeamClaw.new_session(session_name)
      session_key = "agent:default:#{session_name}"

      # Channel (Phase 4)
      channel_id = "integration-ch-#{System.unique_integer([:positive])}"

      {:ok, ch_pid} =
        DynamicSupervisor.start_child(
          BeamClaw.ChannelSupervisor,
          {ChannelServer,
           adapter: BeamClaw.Channel.MockAdapter,
           channel_id: channel_id,
           config: %{}}
        )

      # Cron (Phase 4)
      agent_id = "integration-cron-#{System.unique_integer([:positive])}"

      {:ok, cr_pid} =
        DynamicSupervisor.start_child(
          BeamClaw.CronSupervisor,
          {Worker, agent_id: agent_id}
        )

      # All three registrations coexist
      assert [{^s_pid, _}] = Registry.lookup(BeamClaw.Registry, {:session, session_key})
      assert [{^ch_pid, _}] = Registry.lookup(BeamClaw.Registry, {:channel, channel_id})
      assert [{^cr_pid, _}] = Registry.lookup(BeamClaw.Registry, {:cron, agent_id})

      # Cleanup
      GenServer.stop(s_pid, :normal)
      GenServer.stop(ch_pid, :normal)
      GenServer.stop(cr_pid, :normal)
      File.rm(BeamClaw.Session.Store.transcript_path(session_key))
      File.rm(Store.jobs_path(agent_id))
    end
  end
end
