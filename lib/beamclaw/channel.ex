defmodule BeamClaw.Channel do
  @moduledoc """
  Behaviour for channel adapters.

  A channel adapter connects BeamClaw to an external messaging platform
  (Discord, Slack, IRC, etc.) and handles message normalization and routing.

  ## Example

      defmodule MyAdapter do
        @behaviour BeamClaw.Channel

        @impl true
        def init(config) do
          state = %{token: config["token"]}
          {:ok, state}
        end

        @impl true
        def connect(state) do
          # Establish connection to platform
          {:ok, state}
        end

        @impl true
        def handle_inbound(message, state) do
          normalized = %{
            text: message.content,
            author: message.author_id,
            channel: message.channel_id
          }
          {:ok, normalized, state}
        end

        @impl true
        def send_message(target, content, state) do
          # Send message to platform
          {:ok, state}
        end

        @impl true
        def disconnect(state) do
          :ok
        end
      end
  """

  @doc """
  Initialize the adapter with configuration.

  Returns `{:ok, state}` or `{:error, reason}`.
  """
  @callback init(config :: map()) :: {:ok, state :: term()} | {:error, term()}

  @doc """
  Connect to the external platform.

  Returns `{:ok, state}` or `{:error, reason}`.
  """
  @callback connect(state :: term()) :: {:ok, state :: term()} | {:error, term()}

  @doc """
  Handle an inbound message from the platform.

  Normalizes the platform-specific message to a standard format:
  - `text` - The message content
  - `author` - User/sender identifier
  - `channel` - Channel/room identifier
  - Additional platform-specific fields as needed

  Returns `{:ok, normalized_message, state}` or `{:error, reason, state}`.
  """
  @callback handle_inbound(message :: term(), state :: term()) ::
              {:ok, normalized :: map(), state :: term()}
              | {:error, term(), state :: term()}

  @doc """
  Send a message to the platform.

  Returns `{:ok, state}` or `{:error, reason, state}`.
  """
  @callback send_message(target :: String.t(), content :: String.t(), state :: term()) ::
              {:ok, state :: term()} | {:error, term(), state :: term()}

  @doc """
  Disconnect from the platform.

  Returns `:ok`.
  """
  @callback disconnect(state :: term()) :: :ok

  @doc """
  Optional callback to expose adapter-specific gateway methods.

  Returns a list of method names that can be called via the gateway.
  """
  @callback gateway_methods() :: [String.t()]

  @optional_callbacks [gateway_methods: 0]
end
