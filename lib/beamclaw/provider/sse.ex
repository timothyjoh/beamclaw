defmodule BeamClaw.Provider.SSE do
  @moduledoc """
  Parser for Server-Sent Events (SSE) streams.

  Handles chunked data that may split events across multiple chunks.
  SSE format uses `event:` and `data:` lines separated by `\\n\\n`.

  ## Example SSE Stream

      event: message_start
      data: {"type":"message_start","message":{...}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

  """

  @doc """
  Parses SSE data from a buffer, returning parsed events and remaining buffer.

  Handles incomplete events that span multiple chunks.

  ## Parameters

  - `buffer` - Accumulated string data (may contain partial events)

  ## Returns

  `{events, remaining_buffer}` where:
  - `events` - List of parsed event maps `%{event: String.t(), data: String.t()}`
  - `remaining_buffer` - Unparsed data to carry forward to next chunk

  ## Examples

      iex> SSE.parse("event: ping\\ndata: {}\\n\\n")
      {[%{event: "ping", data: "{}"}], ""}

      iex> SSE.parse("event: start\\ndata: {")
      {[], "event: start\\ndata: {"}

      iex> SSE.parse("}\\n\\n", "event: start\\ndata: {")
      {[%{event: "start", data: "{}"}], ""}
  """
  def parse(chunk, buffer \\ "") do
    combined = buffer <> chunk
    parse_events(combined, [])
  end

  # Private helpers

  defp parse_events(data, acc) do
    case String.split(data, "\n\n", parts: 2) do
      [complete_event, rest] ->
        case parse_event(complete_event) do
          {:ok, event} -> parse_events(rest, [event | acc])
          :incomplete -> {Enum.reverse(acc), data}
        end

      [incomplete] ->
        # No complete event found, return what we have and keep the buffer
        {Enum.reverse(acc), incomplete}
    end
  end

  defp parse_event(event_string) do
    lines = String.split(event_string, "\n")

    event_data =
      Enum.reduce(lines, %{event: nil, data: nil}, fn line, acc ->
        cond do
          String.starts_with?(line, "event:") ->
            %{acc | event: String.trim(String.replace_prefix(line, "event:", ""))}

          String.starts_with?(line, "data:") ->
            %{acc | data: String.trim(String.replace_prefix(line, "data:", ""))}

          true ->
            acc
        end
      end)

    case event_data do
      %{event: event, data: data} when is_binary(event) and is_binary(data) ->
        {:ok, %{event: event, data: data}}

      _ ->
        :incomplete
    end
  end
end
