defmodule BeamClaw.SessionTest do
  use ExUnit.Case

  setup do
    # Generate a truly unique name per test
    test_name = "test-session-#{System.unique_integer([:positive, :monotonic])}"
    test_key = "agent:default:#{test_name}"

    {:ok, pid} = BeamClaw.new_session(test_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      path = BeamClaw.Session.Store.transcript_path(test_key)
      File.rm(path)
    end)

    {:ok, pid: pid, test_key: test_key, test_name: test_name}
  end

  describe "start_link/1" do
    test "starts and registers in Registry", %{pid: pid, test_key: test_key} do
      assert Process.alive?(pid)
      [{found_pid, _}] = Registry.lookup(BeamClaw.Registry, {:session, test_key})
      assert found_pid == pid
    end

    test "parses session key correctly", %{test_key: test_key, test_name: test_name} do
      state = BeamClaw.Session.get_state(test_key)
      assert state.agent_id == "default"
      assert state.session_id == test_name
    end
  end

  describe "get_history/1" do
    test "returns empty list for new session", %{test_key: test_key} do
      history = BeamClaw.Session.get_history(test_key)
      assert history == []
    end
  end

  describe "get_state/1" do
    test "returns session state struct", %{test_key: test_key} do
      state = BeamClaw.Session.get_state(test_key)
      assert state.session_key == test_key
      assert state.status == :idle
      assert is_list(state.messages)
    end
  end
end
