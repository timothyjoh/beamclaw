defmodule BeamClaw.Channel.Server do
  @moduledoc """
  GenServer that wraps a channel adapter.

  This server:
  - Initializes and connects the adapter
  - Registers in BeamClaw.Registry as {:channel, channel_id}
  - Routes inbound messages to sessions
  - Collects streaming responses and sends them back via the adapter

  ## Usage

      # Start a Discord channel
      opts = [
        adapter: BeamClaw.Channel.Discord,
        channel_id: "discord:123456789",
        config: %{"token" => "..."}
      ]
      {:ok, pid} = DynamicSupervisor.start_child(BeamClaw.ChannelSupervisor, {BeamClaw.Channel.Server, opts})

      # Route an inbound message
      GenServer.cast(pid, {:inbound_message, raw_discord_message})
  """

  use GenServer
  require Logger

  defstruct [
    :adapter,
    :channel_id,
    :adapter_state,
    pending_responses: %{}
  ]

  # Client API

  def start_link(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    channel_id = Keyword.fetch!(opts, :channel_id)
    config = Keyword.get(opts, :config, %{})
    GenServer.start_link(__MODULE__, {adapter, channel_id, config}, name: via(channel_id))
  end

  @doc """
  Route an inbound message to the channel.
  """
  def handle_inbound(channel_id, message) do
    GenServer.cast(via(channel_id), {:inbound_message, message})
  end

  # Server Callbacks

  @impl true
  def init({adapter, channel_id, config}) do
    Logger.info("Channel starting: #{channel_id} with adapter #{inspect(adapter)}")

    with {:ok, adapter_state} <- adapter.init(config),
         {:ok, adapter_state} <- adapter.connect(adapter_state) do
      state = %__MODULE__{
        adapter: adapter,
        channel_id: channel_id,
        adapter_state: adapter_state,
        pending_responses: %{}
      }

      Logger.info("Channel connected: #{channel_id}")
      {:ok, state}
    else
      {:error, reason} ->
        Logger.error("Channel failed to start: #{channel_id} - #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:inbound_message, message}, state) do
    case state.adapter.handle_inbound(message, state.adapter_state) do
      {:ok, normalized, adapter_state} ->
        # Route to session
        session_key = get_session_key(normalized)
        text = Map.get(normalized, :text, "")

        # Start collecting response
        correlation_id = generate_correlation_id()

        pending = %{
          target: Map.get(normalized, :channel),
          chunks: [],
          started_at: System.monotonic_time(:millisecond)
        }

        state = put_in(state.pending_responses[correlation_id], pending)

        # Send to session and receive streaming response
        case ensure_session_started(session_key) do
          {:ok, _pid} ->
            # Tag ourselves with correlation_id so we can match responses
            Process.put(:correlation_id, correlation_id)
            BeamClaw.Session.send_message(session_key, text)

          {:error, reason} ->
            Logger.error("Failed to start session #{session_key}: #{inspect(reason)}")
        end

        {:noreply, %{state | adapter_state: adapter_state}}

      {:error, reason, adapter_state} ->
        Logger.error("Failed to handle inbound message: #{inspect(reason)}")
        {:noreply, %{state | adapter_state: adapter_state}}
    end
  end

  @impl true
  def handle_info({:stream_chunk, _session_key, text}, state) do
    correlation_id = Process.get(:correlation_id)

    if correlation_id && Map.has_key?(state.pending_responses, correlation_id) do
      pending = state.pending_responses[correlation_id]
      chunks = pending.chunks ++ [text]
      pending = %{pending | chunks: chunks}
      state = put_in(state.pending_responses[correlation_id], pending)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:stream_done, _session_key, _full_response}, state) do
    correlation_id = Process.get(:correlation_id)

    if correlation_id && Map.has_key?(state.pending_responses, correlation_id) do
      pending = state.pending_responses[correlation_id]
      full_text = Enum.join(pending.chunks)

      # Send response via adapter
      target = pending.target

      case state.adapter.send_message(target, full_text, state.adapter_state) do
        {:ok, adapter_state} ->
          Logger.debug("Sent response to #{target}")
          state = %{state | adapter_state: adapter_state}
          state = %{state | pending_responses: Map.delete(state.pending_responses, correlation_id)}
          Process.delete(:correlation_id)
          {:noreply, state}

        {:error, reason, adapter_state} ->
          Logger.error("Failed to send message: #{inspect(reason)}")
          state = %{state | adapter_state: adapter_state}
          state = %{state | pending_responses: Map.delete(state.pending_responses, correlation_id)}
          Process.delete(:correlation_id)
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:stream_error, _session_key, reason}, state) do
    Logger.error("Stream error: #{inspect(reason)}")
    correlation_id = Process.get(:correlation_id)

    if correlation_id do
      state = %{state | pending_responses: Map.delete(state.pending_responses, correlation_id)}
      Process.delete(:correlation_id)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state.adapter.disconnect(state.adapter_state)
    :ok
  end

  # Private Helpers

  defp via(channel_id) do
    {:via, Registry, {BeamClaw.Registry, {:channel, channel_id}}}
  end

  defp get_session_key(normalized) do
    # Default to "agent:default:main" for now
    # In the future, this could be configurable per channel/guild
    agent_id = Map.get(normalized, :agent_id, "default")
    session_id = Map.get(normalized, :session_id, "main")
    "agent:#{agent_id}:#{session_id}"
  end

  defp ensure_session_started(session_key) do
    case Registry.lookup(BeamClaw.Registry, {:session, session_key}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        # Start the session
        spec = {BeamClaw.Session, session_key: session_key}
        DynamicSupervisor.start_child(BeamClaw.SessionSupervisor, spec)
    end
  end

  defp generate_correlation_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
