defmodule BeamClaw.Provider.Anthropic do
  @moduledoc """
  Anthropic Claude API provider implementation.

  Implements both synchronous and streaming chat completions using the
  Anthropic Messages API with Finch for HTTP/2 connection pooling.

  ## Configuration

  - API key: `ANTHROPIC_API_KEY` environment variable or `BeamClaw.Config`
  - Base URL: https://api.anthropic.com/v1/messages
  - API version: 2023-06-01

  ## Options

  - `:model` - Model to use (default: from config)
  - `:max_tokens` - Maximum tokens to generate (default: from config)
  - `:system` - System prompt string (optional)
  - `:stream_to` - PID to receive streaming events (required for stream_chat)
  """

  @behaviour BeamClaw.Provider

  require Logger

  alias BeamClaw.Provider.SSE

  @base_url "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = get_api_key()
    model = Keyword.get(opts, :model) || BeamClaw.Config.get(:default_model)
    max_tokens = Keyword.get(opts, :max_tokens) || BeamClaw.Config.get(:default_max_tokens)
    system = Keyword.get(opts, :system)

    headers = build_headers(api_key)
    body = build_request_body(messages, model, max_tokens, system, false)

    request =
      Finch.build(:post, @base_url, headers, Jason.encode!(body))

    case Finch.request(request, BeamClaw.Finch) do
      {:ok, %{status: 200, body: response_body}} ->
        parse_response(response_body)

      {:ok, %{status: status, body: error_body}} ->
        {:error, {:http_error, status, error_body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def stream_chat(messages, opts \\ []) do
    case Keyword.get(opts, :stream_to) do
      nil ->
        {:error, :stream_to_required}

      stream_to ->
        api_key = get_api_key()
        model = Keyword.get(opts, :model) || BeamClaw.Config.get(:default_model)
        max_tokens = Keyword.get(opts, :max_tokens) || BeamClaw.Config.get(:default_max_tokens)
        system = Keyword.get(opts, :system)

        headers = build_headers(api_key)
        body = build_request_body(messages, model, max_tokens, system, true)

        request = Finch.build(:post, @base_url, headers, Jason.encode!(body))

        # Spawn a task to handle streaming asynchronously
        Task.start(fn ->
          handle_stream(request, stream_to)
        end)

        :ok
    end
  end

  # Private helpers

  defp get_api_key do
    BeamClaw.Config.get_api_key() ||
      raise "ANTHROPIC_API_KEY not configured"
  end

  defp build_headers(api_key) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"content-type", "application/json"}
    ]
  end

  defp build_request_body(messages, model, max_tokens, system, stream) do
    base = %{
      model: model,
      max_tokens: max_tokens,
      messages: messages,
      stream: stream
    }

    if system do
      Map.put(base, :system, system)
    else
      base
    end
  end

  defp parse_response(body) do
    case Jason.decode(body) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, {:json_decode_error, reason}}
    end
  end

  defp handle_stream(request, stream_to) do
    state = %{
      stream_to: stream_to,
      buffer: "",
      status: nil,
      accumulated_text: "",
      usage: nil
    }

    result =
      Finch.stream(request, BeamClaw.Finch, state, fn
        {:status, status}, acc ->
          %{acc | status: status}

        {:headers, _headers}, acc ->
          acc

        {:data, data}, acc ->
          handle_stream_chunk(data, acc)
      end)

    case result do
      {:ok, final_state} ->
        if final_state.status == 200 do
          send_stream_done(stream_to, final_state.accumulated_text, final_state.usage)
        else
          send(stream_to, {:stream_error, {:http_error, final_state.status}})
        end

      {:error, reason} ->
        send(stream_to, {:stream_error, reason})
    end
  end

  defp handle_stream_chunk(data, state) do
    {events, remaining_buffer} = SSE.parse(data, state.buffer)

    Enum.reduce(events, %{state | buffer: remaining_buffer}, fn event, acc ->
      process_sse_event(event, acc)
    end)
  end

  defp process_sse_event(%{event: event_type, data: data_string}, state) do
    case Jason.decode(data_string) do
      {:ok, data} ->
        send(state.stream_to, {:stream_event, event_type, data})
        update_state_from_event(event_type, data, state)

      {:error, _reason} ->
        # Skip malformed JSON
        state
    end
  end

  defp update_state_from_event("content_block_delta", data, state) do
    text_delta =
      get_in(data, ["delta", "text"]) || ""

    %{state | accumulated_text: state.accumulated_text <> text_delta}
  end

  defp update_state_from_event("message_delta", data, state) do
    usage = get_in(data, ["usage"])
    if usage, do: %{state | usage: usage}, else: state
  end

  defp update_state_from_event(_event_type, _data, state) do
    state
  end

  defp send_stream_done(stream_to, text, usage) do
    result = %{
      content: text,
      usage: usage
    }

    send(stream_to, {:stream_done, result})
  end
end
