defmodule BeamClaw.Channel.Discord do
  @moduledoc """
  Discord channel adapter using Nostrum.

  ## Configuration

      config = %{
        "token" => "Bot YOUR_BOT_TOKEN",
        "guild_id" => "123456789",
        "channel_id" => "987654321"
      }

  ## Usage

      opts = [
        adapter: BeamClaw.Channel.Discord,
        channel_id: "discord:123456789",
        config: config
      ]
      {:ok, pid} = DynamicSupervisor.start_child(BeamClaw.ChannelSupervisor, {BeamClaw.Channel.Server, opts})
  """

  @behaviour BeamClaw.Channel

  require Logger

  defstruct [:token, :guild_id, :channel_id]

  @impl true
  def init(config) do
    token = config["token"]
    guild_id = config["guild_id"]
    channel_id = config["channel_id"]

    if is_nil(token) or token == "" do
      {:error, :missing_token}
    else
      state = %__MODULE__{
        token: token,
        guild_id: guild_id,
        channel_id: channel_id
      }

      {:ok, state}
    end
  end

  @impl true
  def connect(state) do
    # Nostrum handles its own connection lifecycle via its supervision tree
    # The bot token is configured in config/config.exs or runtime.exs
    # We just verify the state is ready
    Logger.info("Discord adapter connected for channel #{state.channel_id}")
    {:ok, state}
  end

  @impl true
  def handle_inbound(message, state) do
    # Normalize Discord message to standard format
    # message is expected to be a Nostrum.Struct.Message
    normalized = %{
      text: message.content,
      author: to_string(message.author.id),
      channel: to_string(message.channel_id),
      guild: if(message.guild_id, do: to_string(message.guild_id), else: nil),
      message_id: to_string(message.id),
      timestamp: message.timestamp
    }

    {:ok, normalized, state}
  end

  @impl true
  def send_message(target, content, state) do
    # target is the channel_id as a string
    channel_id = String.to_integer(target)

    case Nostrum.Api.Message.create(channel_id, content) do
      {:ok, _message} ->
        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to send Discord message: #{inspect(reason)}")
        {:error, reason, state}
    end
  end

  @impl true
  def disconnect(state) do
    Logger.info("Discord adapter disconnected for channel #{state.channel_id}")
    :ok
  end

  @impl true
  def gateway_methods do
    ["send_message", "get_channel_info"]
  end
end
