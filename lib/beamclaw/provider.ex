defmodule BeamClaw.Provider do
  @moduledoc """
  Behaviour for LLM provider implementations.

  Providers must implement both synchronous and streaming chat methods.
  """

  @doc """
  Sends a chat request and returns the complete response.

  ## Parameters

  - `messages` - List of message maps with `:role` and `:content` keys
  - `opts` - Keyword list of options (model, max_tokens, system, etc.)

  ## Returns

  - `{:ok, response_map}` - Successful response with content and metadata
  - `{:error, reason}` - Error with reason term
  """
  @callback chat(messages :: list(map()), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Sends a streaming chat request and sends events to the caller process.

  ## Parameters

  - `messages` - List of message maps with `:role` and `:content` keys
  - `opts` - Keyword list of options. MUST include `:stream_to` pid.

  ## Expected Messages to stream_to Process

  - `{:stream_event, event_type, data}` - For each SSE event
  - `{:stream_done, final_response}` - When streaming completes successfully
  - `{:stream_error, reason}` - If an error occurs

  ## Returns

  - `:ok` - Stream initiated successfully
  - `{:error, reason}` - Failed to initiate stream
  """
  @callback stream_chat(messages :: list(map()), opts :: keyword()) ::
              :ok | {:error, term()}
end
