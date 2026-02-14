defmodule BeamClaw.Session.SubAgentTest do
  use ExUnit.Case, async: false

  alias BeamClaw.Session
  alias BeamClaw.Session.SubAgent

  setup do
    # Create a unique parent session for each test
    parent_key = "agent:test:parent-#{System.unique_integer([:positive])}"

    {:ok, _pid} = DynamicSupervisor.start_child(
      BeamClaw.SessionSupervisor,
      {Session, session_key: parent_key}
    )

    %{parent_key: parent_key}
  end

  describe "spawn/2" do
    test "spawns a sub-agent successfully", %{parent_key: parent_key} do
      {:ok, run} = SubAgent.spawn(parent_key, task: "Test task")

      assert run.status == :running
      assert run.task == "Test task"
      assert run.parent_session_key == parent_key
      assert run.cleanup == :delete
      assert is_binary(run.run_id)
      assert is_pid(run.child_pid)
      assert Process.alive?(run.child_pid)

      # Verify child session key format
      assert run.child_session_key =~ ~r/^agent:test:subagent:[0-9a-f]+$/
    end

    test "accepts optional parameters", %{parent_key: parent_key} do
      {:ok, run} = SubAgent.spawn(parent_key,
        task: "Complex task",
        label: "My Label",
        cleanup: :keep,
        agent_id: "custom"
      )

      assert run.label == "My Label"
      assert run.cleanup == :keep
      assert run.child_session_key =~ ~r/^agent:custom:subagent:/
    end

    test "returns error when parent session doesn't exist" do
      assert {:error, :parent_not_found} = SubAgent.spawn("agent:nonexistent:key", task: "Task")
    end

    test "sub-agent cannot spawn sub-sub-agent", %{parent_key: parent_key} do
      # First, spawn a child
      {:ok, child_run} = SubAgent.spawn(parent_key, task: "Child task")

      # Try to spawn from the child (should fail)
      assert {:error, :sub_agents_cannot_spawn} =
        SubAgent.spawn(child_run.child_session_key, task: "Grandchild task")
    end
  end

  describe "list_runs/1" do
    test "returns empty list when no sub-agents", %{parent_key: parent_key} do
      assert [] = SubAgent.list_runs(parent_key)
    end

    test "lists all active sub-agents", %{parent_key: parent_key} do
      {:ok, run1} = SubAgent.spawn(parent_key, task: "Task 1")
      {:ok, run2} = SubAgent.spawn(parent_key, task: "Task 2")

      runs = SubAgent.list_runs(parent_key)

      assert length(runs) == 2
      run_ids = Enum.map(runs, & &1.run_id) |> Enum.sort()
      assert Enum.sort([run1.run_id, run2.run_id]) == run_ids
    end

    test "returns empty list for non-existent session" do
      assert [] = SubAgent.list_runs("agent:nonexistent:key")
    end
  end

  describe "get_run/2" do
    test "retrieves a specific run by ID", %{parent_key: parent_key} do
      {:ok, run} = SubAgent.spawn(parent_key, task: "Task")

      retrieved = SubAgent.get_run(parent_key, run.run_id)

      assert retrieved.run_id == run.run_id
      assert retrieved.task == "Task"
    end

    test "returns nil for non-existent run_id", %{parent_key: parent_key} do
      assert nil == SubAgent.get_run(parent_key, "nonexistent")
    end

    test "returns nil for non-existent parent" do
      assert nil == SubAgent.get_run("agent:nonexistent:key", "some-id")
    end
  end

  describe "cleanup_run/2" do
    test "stops the child session and removes from parent", %{parent_key: parent_key} do
      {:ok, run} = SubAgent.spawn(parent_key, task: "Task")
      child_pid = run.child_pid

      assert Process.alive?(child_pid)

      assert :ok = SubAgent.cleanup_run(parent_key, run.run_id)

      # Child should be terminated
      refute Process.alive?(child_pid)

      # Run should be removed from list
      runs = SubAgent.list_runs(parent_key)
      assert [] = runs
    end

    test "returns error when parent doesn't exist" do
      assert {:error, :parent_not_found} =
        SubAgent.cleanup_run("agent:nonexistent:key", "some-id")
    end

    test "returns error when run doesn't exist", %{parent_key: parent_key} do
      assert {:error, :run_not_found} =
        SubAgent.cleanup_run(parent_key, "nonexistent-id")
    end

    test "handles already-dead child gracefully", %{parent_key: parent_key} do
      {:ok, run} = SubAgent.spawn(parent_key, task: "Task")
      child_pid = run.child_pid

      # Manually kill the child
      Process.exit(child_pid, :kill)
      Process.sleep(50) # Give it time to die

      refute Process.alive?(child_pid)

      # Cleanup should still work
      assert :ok = SubAgent.cleanup_run(parent_key, run.run_id)

      # Run should be removed
      assert [] = SubAgent.list_runs(parent_key)
    end
  end

  describe "monitor and :DOWN handling" do
    test "parent detects when child exits normally", %{parent_key: parent_key} do
      {:ok, run} = SubAgent.spawn(parent_key, task: "Task")
      child_pid = run.child_pid

      # Monitor the child ourselves to know when it's actually gone
      ref = Process.monitor(child_pid)

      # Stop the child normally
      DynamicSupervisor.terminate_child(BeamClaw.SessionSupervisor, child_pid)

      # Wait for child to actually exit
      receive do
        {:DOWN, ^ref, :process, ^child_pid, _} -> :ok
      after
        1000 -> flunk("Child process did not exit")
      end

      # Give parent time to process its :DOWN message
      Process.sleep(50)

      # Check parent's state
      runs = SubAgent.list_runs(parent_key)
      assert length(runs) == 1

      [updated_run] = runs
      assert updated_run.run_id == run.run_id
      assert updated_run.status == :completed
      # DynamicSupervisor.terminate_child sends :shutdown, not :normal
      assert updated_run.outcome == :shutdown
      assert updated_run.ended_at != nil
    end

    test "parent detects when child crashes", %{parent_key: parent_key} do
      {:ok, run} = SubAgent.spawn(parent_key, task: "Task")
      child_pid = run.child_pid

      # Monitor the child ourselves to know when it's actually gone
      ref = Process.monitor(child_pid)

      # Kill the child
      Process.exit(child_pid, :kill)

      # Wait for child to actually exit
      receive do
        {:DOWN, ^ref, :process, ^child_pid, _} -> :ok
      after
        1000 -> flunk("Child process did not exit")
      end

      # Give parent time to process its :DOWN message
      Process.sleep(50)

      # Check parent's state
      runs = SubAgent.list_runs(parent_key)
      assert length(runs) == 1

      [updated_run] = runs
      assert updated_run.run_id == run.run_id
      assert updated_run.status == :failed
      assert updated_run.outcome == :killed
      assert updated_run.ended_at != nil
    end
  end

  describe "child session key format" do
    test "child session has correct format with unique ID", %{parent_key: parent_key} do
      {:ok, run1} = SubAgent.spawn(parent_key, task: "Task 1")
      {:ok, run2} = SubAgent.spawn(parent_key, task: "Task 2")

      # Both should match the pattern
      assert run1.child_session_key =~ ~r/^agent:test:subagent:[0-9a-f]{8}$/
      assert run2.child_session_key =~ ~r/^agent:test:subagent:[0-9a-f]{8}$/

      # Should be different
      assert run1.child_session_key != run2.child_session_key
      assert run1.run_id != run2.run_id
    end

    test "child session can be looked up by its key", %{parent_key: parent_key} do
      {:ok, run} = SubAgent.spawn(parent_key, task: "Task")

      # Verify we can get the child session's state
      child_state = Session.get_state(run.child_session_key)

      assert child_state.session_key == run.child_session_key
      assert child_state.parent_session != nil
      assert is_pid(child_state.parent_session)
    end
  end
end
