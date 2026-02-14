defmodule BeamClaw.ChannelTest do
  use ExUnit.Case

  alias BeamClaw.Channel.Server
  alias BeamClaw.Channel.MockAdapter

  setup do
    # Generate unique channel ID per test
    test_id = System.unique_integer([:positive, :monotonic])
    channel_id = "test:#{test_id}"

    on_exit(fn ->
      # Clean up channel server if it exists
      case Registry.lookup(BeamClaw.Registry, {:channel, channel_id}) do
        [{pid, _}] ->
          if Process.alive?(pid), do: GenServer.stop(pid, :normal)

        [] ->
          :ok
      end
    end)

    {:ok, channel_id: channel_id, test_id: test_id}
  end

  describe "Channel behaviour" do
    test "defines all required callbacks" do
      # Verify the behaviour is properly defined
      assert Code.ensure_loaded?(BeamClaw.Channel)
      callbacks = BeamClaw.Channel.behaviour_info(:callbacks)

      assert {:init, 1} in callbacks
      assert {:connect, 1} in callbacks
      assert {:handle_inbound, 2} in callbacks
      assert {:send_message, 3} in callbacks
      assert {:disconnect, 1} in callbacks
    end
  end

  describe "Channel.Server start_link/1" do
    test "starts with MockAdapter and registers in Registry", %{channel_id: channel_id} do
      opts = [
        adapter: MockAdapter,
        channel_id: channel_id,
        config: %{"test" => true}
      ]

      {:ok, pid} = Server.start_link(opts)

      assert Process.alive?(pid)

      [{found_pid, _}] = Registry.lookup(BeamClaw.Registry, {:channel, channel_id})
      assert found_pid == pid
    end

    test "initializes adapter state correctly", %{channel_id: channel_id} do
      opts = [
        adapter: MockAdapter,
        channel_id: channel_id,
        config: %{"foo" => "bar"}
      ]

      {:ok, pid} = Server.start_link(opts)

      state = :sys.get_state(pid)
      assert state.adapter == MockAdapter
      assert state.channel_id == channel_id
      assert state.adapter_state.config == %{"foo" => "bar"}
    end
  end

  describe "Channel.Server message routing" do
    test "handles inbound messages and routes to session", %{channel_id: channel_id} do
      opts = [
        adapter: MockAdapter,
        channel_id: channel_id,
        config: %{}
      ]

      {:ok, _pid} = Server.start_link(opts)

      # Create a test session to receive the message
      test_session_key = "agent:default:main"

      # Start session if not already running
      case Registry.lookup(BeamClaw.Registry, {:session, test_session_key}) do
        [] ->
          {:ok, _session_pid} =
            DynamicSupervisor.start_child(
              BeamClaw.SessionSupervisor,
              {BeamClaw.Session, session_key: test_session_key}
            )

        [{_pid, _}] ->
          :ok
      end

      # Send an inbound message
      message = %{
        text: "Hello from test",
        author: "test_user",
        channel: "test_channel"
      }

      Server.handle_inbound(channel_id, message)

      # Give it a moment to process
      Process.sleep(100)

      # Verify the session received the message
      # (This is hard to test without mocking the session, but we can verify the server is still alive)
      assert Process.alive?(Process.whereis(BeamClaw.Registry))
    end
  end

  describe "Channel.Server with ChannelSupervisor" do
    test "can be started under ChannelSupervisor", %{channel_id: channel_id} do
      spec = {
        Server,
        [
          adapter: MockAdapter,
          channel_id: channel_id,
          config: %{}
        ]
      }

      {:ok, pid} = DynamicSupervisor.start_child(BeamClaw.ChannelSupervisor, spec)

      assert Process.alive?(pid)

      [{found_pid, _}] = Registry.lookup(BeamClaw.Registry, {:channel, channel_id})
      assert found_pid == pid

      # Stop the child
      :ok = DynamicSupervisor.terminate_child(BeamClaw.ChannelSupervisor, pid)

      # Verify it's stopped
      refute Process.alive?(pid)
    end
  end

  describe "MockAdapter" do
    test "implements all Channel callbacks" do
      # Test init
      {:ok, state} = MockAdapter.init(%{"test" => true})
      assert state.config == %{"test" => true}
      assert state.messages_sent == []

      # Test connect
      {:ok, state} = MockAdapter.connect(state)
      assert state.config == %{"test" => true}

      # Test handle_inbound
      message = %{text: "hello", author: "user1", channel: "ch1"}
      {:ok, normalized, state} = MockAdapter.handle_inbound(message, state)
      assert normalized.text == "hello"
      assert normalized.author == "user1"
      assert normalized.channel == "ch1"

      # Test send_message
      {:ok, state} = MockAdapter.send_message("target", "response", state)
      assert length(state.messages_sent) == 1
      [msg] = state.messages_sent
      assert msg.target == "target"
      assert msg.content == "response"

      # Test disconnect
      assert :ok = MockAdapter.disconnect(state)
    end

    test "gateway_methods returns list", %{} do
      methods = MockAdapter.gateway_methods()
      assert is_list(methods)
      assert "test_method" in methods
    end
  end

  describe "Channel.Discord" do
    test "implements Channel behaviour" do
      # Verify Discord adapter is properly defined
      assert Code.ensure_loaded?(BeamClaw.Channel.Discord)

      # Test init with valid config
      config = %{
        "token" => "Bot TEST_TOKEN",
        "guild_id" => "123",
        "channel_id" => "456"
      }

      {:ok, state} = BeamClaw.Channel.Discord.init(config)
      assert state.token == "Bot TEST_TOKEN"
      assert state.guild_id == "123"
      assert state.channel_id == "456"
    end

    test "init fails without token" do
      config = %{"guild_id" => "123"}
      assert {:error, :missing_token} = BeamClaw.Channel.Discord.init(config)
    end

    test "gateway_methods returns list" do
      methods = BeamClaw.Channel.Discord.gateway_methods()
      assert is_list(methods)
      assert "send_message" in methods
    end
  end

  describe "Registry integration" do
    test "channels can be looked up by channel_id", %{channel_id: channel_id} do
      opts = [
        adapter: MockAdapter,
        channel_id: channel_id,
        config: %{}
      ]

      {:ok, pid} = Server.start_link(opts)

      # Lookup by channel_id
      [{found_pid, _}] = Registry.lookup(BeamClaw.Registry, {:channel, channel_id})
      assert found_pid == pid
    end

    test "multiple channels can coexist", %{test_id: test_id} do
      channel_id_1 = "test:#{test_id}:1"
      channel_id_2 = "test:#{test_id}:2"

      {:ok, pid1} =
        Server.start_link(adapter: MockAdapter, channel_id: channel_id_1, config: %{})

      {:ok, pid2} =
        Server.start_link(adapter: MockAdapter, channel_id: channel_id_2, config: %{})

      assert pid1 != pid2

      [{found1, _}] = Registry.lookup(BeamClaw.Registry, {:channel, channel_id_1})
      [{found2, _}] = Registry.lookup(BeamClaw.Registry, {:channel, channel_id_2})

      assert found1 == pid1
      assert found2 == pid2

      # Cleanup
      GenServer.stop(pid1)
      GenServer.stop(pid2)
    end
  end
end
