defmodule BeamClaw.Gateway.ChatController do
  use Phoenix.Controller, formats: [:json]
  require Logger

  @doc """
  POST /v1/chat/completions

  OpenAI-compatible chat completions endpoint.
  Supports both streaming and non-streaming responses.
  """
  def completions(conn, params) do
    # Validate required fields
    messages = params["messages"]

    if is_nil(messages) or not is_list(messages) or Enum.empty?(messages) do
      conn
      |> put_status(400)
      |> json(%{error: %{message: "messages is required and must be a non-empty array"}})
    else
      model = params["model"] || "claude-sonnet-4-5-20250929"
      stream = params["stream"] || false

      if stream do
        handle_streaming_request(conn, messages, model)
      else
        handle_non_streaming_request(conn, messages, model)
      end
    end
  end

  # Non-streaming response
  defp handle_non_streaming_request(conn, messages, model) do
    # Create ephemeral session
    session_name = "api-" <> generate_id()
    {:ok, _pid} = BeamClaw.new_session(session_name)
    session_key = "agent:default:#{session_name}"

    try do
      # Extract the last user message
      last_message = List.last(messages)
      user_content = last_message["content"] || ""

      # Send message and wait for response
      case BeamClaw.Session.send_message_sync(session_key, user_content, 60_000) do
        {:ok, response_text} ->
          # Build OpenAI-compatible response
          response = %{
            id: "chatcmpl-" <> generate_id(),
            object: "chat.completion",
            created: System.system_time(:second),
            model: model,
            choices: [
              %{
                index: 0,
                message: %{
                  role: "assistant",
                  content: response_text
                },
                finish_reason: "stop"
              }
            ],
            usage: %{
              prompt_tokens: 0,
              completion_tokens: 0,
              total_tokens: 0
            }
          }

          json(conn, response)

        {:error, reason} ->
          Logger.error("Session error: #{inspect(reason)}")

          conn
          |> put_status(500)
          |> json(%{error: %{message: "Internal server error", details: inspect(reason)}})
      end
    after
      # Clean up ephemeral session
      cleanup_session(session_key)
    end
  end

  # Streaming response
  defp handle_streaming_request(conn, messages, model) do
    # Create ephemeral session
    session_name = "api-" <> generate_id()
    {:ok, _pid} = BeamClaw.new_session(session_name)
    session_key = "agent:default:#{session_name}"

    # Extract the last user message
    last_message = List.last(messages)
    user_content = last_message["content"] || ""

    # Set SSE headers
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    # Send the message
    BeamClaw.Session.send_message(session_key, user_content)

    # Stream the response
    completion_id = "chatcmpl-" <> generate_id()
    stream_response(conn, session_key, model, completion_id)

    # Clean up ephemeral session
    cleanup_session(session_key)

    conn
  end

  defp stream_response(conn, session_key, model, completion_id) do
    receive do
      {:stream_chunk, ^session_key, text} ->
        # Send SSE chunk in OpenAI format
        chunk = %{
          id: completion_id,
          object: "chat.completion.chunk",
          created: System.system_time(:second),
          model: model,
          choices: [
            %{
              index: 0,
              delta: %{
                content: text
              },
              finish_reason: nil
            }
          ]
        }

        data = "data: " <> Jason.encode!(chunk) <> "\n\n"
        {:ok, conn} = chunk(conn, data)

        # Continue streaming
        stream_response(conn, session_key, model, completion_id)

      {:stream_done, ^session_key, _full_response} ->
        # Send final chunk with finish_reason
        final_chunk = %{
          id: completion_id,
          object: "chat.completion.chunk",
          created: System.system_time(:second),
          model: model,
          choices: [
            %{
              index: 0,
              delta: %{},
              finish_reason: "stop"
            }
          ]
        }

        data = "data: " <> Jason.encode!(final_chunk) <> "\n\n"
        {:ok, conn} = chunk(conn, data)

        # Send [DONE] marker
        {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
        conn

      {:stream_error, ^session_key, reason} ->
        Logger.error("Stream error: #{inspect(reason)}")

        error = %{
          error: %{
            message: "Stream error",
            details: inspect(reason)
          }
        }

        data = "data: " <> Jason.encode!(error) <> "\n\n"
        {:ok, conn} = chunk(conn, data)
        conn
    after
      60_000 ->
        Logger.error("Stream timeout for session #{session_key}")
        {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
        conn
    end
  end

  defp cleanup_session(session_key) do
    case Registry.lookup(BeamClaw.Registry, {:session, session_key}) do
      [{pid, _}] ->
        GenServer.stop(pid, :normal)
        Logger.debug("Cleaned up ephemeral session: #{session_key}")

      [] ->
        :ok
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16(case: :lower)
  end
end
