defmodule BeamClaw.Channel.MockAdapter do
  @moduledoc """
  Mock channel adapter for testing.

  Stores sent messages in the process state and allows inspection.
  """

  @behaviour BeamClaw.Channel

  defstruct messages_sent: [], config: %{}

  @impl true
  def init(config) do
    state = %__MODULE__{config: config}
    {:ok, state}
  end

  @impl true
  def connect(state) do
    {:ok, state}
  end

  @impl true
  def handle_inbound(message, state) do
    # Expect message to be a map with :text, :author, :channel
    normalized = %{
      text: Map.get(message, :text, ""),
      author: Map.get(message, :author, "test_user"),
      channel: Map.get(message, :channel, "test_channel")
    }

    {:ok, normalized, state}
  end

  @impl true
  def send_message(target, content, state) do
    message = %{target: target, content: content, timestamp: System.monotonic_time()}
    messages = state.messages_sent ++ [message]
    {:ok, %{state | messages_sent: messages}}
  end

  @impl true
  def disconnect(_state) do
    :ok
  end

  @impl true
  def gateway_methods do
    ["test_method"]
  end

  @doc """
  Get all messages sent by this adapter (for testing).
  """
  def get_sent_messages(channel_id) do
    case Registry.lookup(BeamClaw.Registry, {:channel, channel_id}) do
      [{pid, _}] ->
        :sys.get_state(pid).adapter_state.messages_sent

      [] ->
        []
    end
  end
end
