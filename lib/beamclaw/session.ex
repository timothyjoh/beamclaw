defmodule BeamClaw.Session do
  @moduledoc """
  GenServer that manages a conversation session.

  Each session:
  - Is registered in BeamClaw.Registry as {:session, session_key}
  - Is started under BeamClaw.SessionSupervisor
  - Holds message history in state
  - Streams responses from the Anthropic provider

  ## Usage

      # Start a session
      {:ok, pid} = BeamClaw.Session.start_link(session_key: "agent:default:main")

      # Send a message
      BeamClaw.Session.send_message("agent:default:main", "Hello!")

      # Wait for streaming response
      BeamClaw.Session.send_message_sync("agent:default:main", "What is 2+2?")

      # Get message history
      BeamClaw.Session.get_history("agent:default:main")
  """

  use GenServer
  require Logger

  alias BeamClaw.Session.Store

  defstruct [
    :session_key,
    :agent_id,
    :session_id,
    :caller,
    messages: [],
    metadata: %{},
    status: :idle
  ]

  # Client API

  @doc """
  Starts a session GenServer.

  Options:
  - `session_key` (required) - Full session key like "agent:default:main"
  - `agent_id` (optional) - Extracted from session_key if not provided
  - `session_id` (optional) - Extracted from session_key if not provided
  """
  def start_link(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    GenServer.start_link(__MODULE__, opts, name: via(session_key))
  end

  @doc """
  Sends a user message asynchronously.

  The response will be streamed to the calling process via:
  - `{:stream_chunk, session_key, text}` - Text delta
  - `{:stream_done, session_key, full_response}` - Complete response
  - `{:stream_error, session_key, reason}` - Error occurred
  """
  def send_message(session_key, text) do
    GenServer.cast(via(session_key), {:send_message, text, self()})
  end

  @doc """
  Sends a user message and waits for the complete response.

  Returns `{:ok, response_text}` or `{:error, reason}`.
  """
  def send_message_sync(session_key, text, timeout \\ 30_000) do
    send_message(session_key, text)
    drain_until_done(session_key, timeout)
  end

  defp drain_until_done(session_key, timeout) do
    receive do
      {:stream_chunk, ^session_key, _text} ->
        drain_until_done(session_key, timeout)

      {:stream_done, ^session_key, full_response} ->
        {:ok, full_response}

      {:stream_error, ^session_key, reason} ->
        {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Returns the message history for a session.
  """
  def get_history(session_key) do
    GenServer.call(via(session_key), :get_history)
  end

  @doc """
  Returns the full session state.
  """
  def get_state(session_key) do
    GenServer.call(via(session_key), :get_state)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    {agent_id, session_id} = parse_session_key(session_key)

    state = %__MODULE__{
      session_key: session_key,
      agent_id: Keyword.get(opts, :agent_id, agent_id),
      session_id: Keyword.get(opts, :session_id, session_id),
      messages: [],
      metadata: %{},
      status: :idle
    }

    # Load existing messages from JSONL if available
    loaded_messages = Store.load_messages(session_key)

    state = %{state | messages: loaded_messages}

    Logger.info("Session started: #{session_key}")
    {:ok, state}
  end

  @impl true
  def handle_cast({:send_message, text, caller_pid}, state) do
    # Add user message to history
    user_message = %{role: "user", content: text}
    messages = state.messages ++ [user_message]

    # Persist user message
    Store.append_message(state.session_key, user_message)

    # Build messages for API call
    api_messages = Enum.map(messages, fn msg ->
      %{"role" => msg.role, "content" => msg.content}
    end)

    # Get config
    model = BeamClaw.Config.get(:default_model)
    max_tokens = BeamClaw.Config.get(:default_max_tokens)

    # Start streaming chat
    opts = [
      model: model,
      max_tokens: max_tokens,
      system: "You are a helpful AI assistant.",
      stream_to: self()
    ]

    # stream_chat already spawns its own async Task internally,
    # so we call it directly — stream events come to self() (the GenServer)
    case BeamClaw.Provider.Anthropic.stream_chat(api_messages, opts) do
      :ok -> :ok
      {:error, reason} ->
        send(self(), {:stream_error, reason})
    end

    state = %{state | messages: messages, caller: caller_pid, status: :processing}
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, state.messages, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info({:stream_event, "content_block_delta", data}, state) do
    # Extract text delta and forward to caller
    text = get_in(data, ["delta", "text"]) || ""

    if state.caller && text != "" do
      send(state.caller, {:stream_chunk, state.session_key, text})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:stream_done, response}, state) do
    # Extract full content
    full_text = response.content || ""

    # Add assistant message to history
    assistant_message = %{role: "assistant", content: full_text}
    messages = state.messages ++ [assistant_message]

    # Persist assistant message
    Store.append_message(state.session_key, assistant_message)

    # Notify caller
    if state.caller do
      send(state.caller, {:stream_done, state.session_key, full_text})
    end

    state = %{state | messages: messages, caller: nil, status: :idle}
    {:noreply, state}
  end

  @impl true
  def handle_info({:stream_error, reason}, state) do
    Logger.error("Stream error in session #{state.session_key}: #{inspect(reason)}")

    # Notify caller
    if state.caller do
      send(state.caller, {:stream_error, state.session_key, reason})
    end

    state = %{state | caller: nil, status: :idle}
    {:noreply, state}
  end

  # Catch-all for other stream events we don't handle yet
  @impl true
  def handle_info({:stream_event, _type, _data}, state) do
    {:noreply, state}
  end

  # Private Helpers

  defp via(session_key) do
    {:via, Registry, {BeamClaw.Registry, {:session, session_key}}}
  end

  defp parse_session_key(session_key) do
    case String.split(session_key, ":") do
      ["agent", agent_id, session_id] -> {agent_id, session_id}
      _ -> raise ArgumentError, "Invalid session_key format: #{session_key}"
    end
  end
end
