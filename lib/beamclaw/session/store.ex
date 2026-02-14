defmodule BeamClaw.Session.Store do
  @moduledoc """
  JSONL persistence for session transcripts.

  Stores message history in JSONL format following the OpenClaw pattern:
  - One JSON object per line
  - First line is session metadata
  - Subsequent lines are messages with timestamps

  ## File Format

  ```jsonl
  {"type":"session","version":1,"session_key":"agent:default:main","created_at":"2024-01-01T00:00:00Z"}
  {"message":{"role":"user","content":"Hello","timestamp":1704067200000}}
  {"message":{"role":"assistant","content":"Hi there!","timestamp":1704067201000}}
  ```

  ## File Location

  Transcripts are stored in `~/.config/beamclaw/data/sessions/` by default.
  The data directory can be configured via `BeamClaw.Config`.

  Session keys like "agent:default:main" are converted to safe filenames
  by replacing colons with dashes: "agent-default-main.jsonl"
  """

  require Logger

  @doc """
  Returns the path to the transcript file for a session.

  ## Examples

      iex> transcript_path("agent:default:main")
      "/Users/user/.config/beamclaw/data/sessions/agent-default-main.jsonl"
  """
  def transcript_path(session_key) do
    data_dir = BeamClaw.Config.get(:data_dir)
    sessions_dir = Path.join(data_dir, "sessions")
    filename = String.replace(session_key, ":", "-") <> ".jsonl"
    Path.join(sessions_dir, filename)
  end

  @doc """
  Appends a message to the session transcript.

  Creates the transcript file with session header if it doesn't exist.

  ## Examples

      iex> append_message("agent:default:main", %{role: "user", content: "Hello"})
      :ok
  """
  def append_message(session_key, message) do
    path = transcript_path(session_key)

    # Ensure directory exists
    ensure_dir(path)

    # Check if file exists; if not, write session header first
    file_exists = File.exists?(path)

    lines_to_write =
      if file_exists do
        [encode_message(message)]
      else
        [encode_session_header(session_key), encode_message(message)]
      end

    # Append to file
    content = Enum.join(lines_to_write, "\n") <> "\n"

    case File.write(path, content, [:append]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to write message to #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Loads all messages from a session transcript.

  Returns an empty list if the file doesn't exist.

  ## Examples

      iex> load_messages("agent:default:main")
      [%{role: "user", content: "Hello"}, %{role: "assistant", content: "Hi!"}]
  """
  def load_messages(session_key) do
    path = transcript_path(session_key)

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(&decode_line/1)
      |> Stream.filter(&match?({:message, _}, &1))
      |> Enum.map(fn {:message, msg} -> msg end)
    else
      []
    end
  end

  @doc """
  Ensures the parent directory of a file path exists.
  """
  def ensure_dir(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()
  end

  # Private Helpers

  defp encode_session_header(session_key) do
    Jason.encode!(%{
      type: "session",
      version: 1,
      session_key: session_key,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp encode_message(message) do
    Jason.encode!(%{
      message: %{
        role: message.role,
        content: message.content,
        timestamp: System.system_time(:millisecond)
      }
    })
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{"message" => msg}} ->
        {:message, %{role: msg["role"], content: msg["content"]}}

      {:ok, %{"type" => "session"}} ->
        {:session_header, nil}

      {:error, reason} ->
        Logger.warning("Failed to decode JSONL line: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
