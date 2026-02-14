defmodule BeamClaw do
  @moduledoc """
  BeamClaw - BEAM/Elixir implementation of OpenClaw AI agent orchestration platform.

  BeamClaw is a concurrent, fault-tolerant agent orchestration system built on the BEAM VM.
  It provides session management, event streaming, tool execution, and multi-provider LLM support.

  ## Core Components

  - `BeamClaw.Session` - Manages agent conversations and state
  - `BeamClaw.Config` - Runtime configuration management
  - `BeamClaw.Registry` - Process lookup and registration

  ## Configuration

  See `BeamClaw.Config` for runtime configuration options.

  ## Quick Start

      # Start a new session
      BeamClaw.new_session("test")

      # Chat with the AI
      BeamClaw.chat("test", "What is the capital of France?")

      # View message history
      BeamClaw.history("test")
  """

  @doc """
  Creates a new session.

  The session is started under `BeamClaw.SessionSupervisor` and registered
  in `BeamClaw.Registry` with a key based on the session name.

  Returns `{:ok, pid}` or `{:error, reason}`.

  ## Examples

      iex> BeamClaw.new_session("main")
      {:ok, #PID<0.123.0>}

      iex> BeamClaw.new_session("testing")
      {:ok, #PID<0.124.0>}
  """
  def new_session(name \\ "main") do
    session_key = "agent:default:#{name}"

    DynamicSupervisor.start_child(
      BeamClaw.SessionSupervisor,
      {BeamClaw.Session, session_key: session_key}
    )
  end

  @doc """
  Sends a message to a session and waits for the complete response.

  Streams text chunks to the console as they arrive, then returns the full response.

  Returns `{:ok, response_text}` or `{:error, reason}`.

  ## Examples

      iex> BeamClaw.chat("main", "What is 2+2?")
      4
      {:ok, "4"}

      iex> BeamClaw.chat("test", "Tell me a joke")
      Why did the chicken cross the road? To get to the other side!
      {:ok, "Why did the chicken cross the road? To get to the other side!"}
  """
  def chat(name \\ "main", message) do
    session_key = "agent:default:#{name}"
    BeamClaw.Session.send_message(session_key, message)
    receive_streaming_response(session_key)
  end

  @doc """
  Gets the message history for a session.

  Returns a list of message maps with `:role` and `:content` keys.

  ## Examples

      iex> BeamClaw.history("main")
      [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]
  """
  def history(name \\ "main") do
    session_key = "agent:default:#{name}"
    BeamClaw.Session.get_history(session_key)
  end

  # Private Helpers

  defp receive_streaming_response(session_key) do
    receive do
      {:stream_chunk, ^session_key, text} ->
        IO.write(text)
        receive_streaming_response(session_key)

      {:stream_done, ^session_key, full_response} ->
        IO.puts("")
        {:ok, full_response}

      {:stream_error, ^session_key, reason} ->
        IO.puts("\nError: #{inspect(reason)}")
        {:error, reason}
    after
      60_000 -> {:error, :timeout}
    end
  end
end
