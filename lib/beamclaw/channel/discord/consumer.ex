defmodule BeamClaw.Channel.Discord.Consumer do
  @moduledoc """
  Nostrum consumer that receives Discord events and forwards them to Channel.Server.

  This consumer listens for MESSAGE_CREATE events and routes them to the appropriate
  Channel.Server GenServer based on the channel mapping.

  ## Configuration

  The consumer needs to know which Discord channels map to which BeamClaw channel servers.
  This mapping is managed via the channel configuration.

  ## Usage

  The consumer is automatically started by Nostrum's supervision tree when configured
  in config/config.exs:

      config :nostrum,
        token: System.get_env("DISCORD_BOT_TOKEN"),
        num_shards: :auto

  Then the consumer is referenced in your application supervision tree or started manually.
  """

  use Nostrum.Consumer

  require Logger

  @doc """
  Handle Discord events.

  ## Events

  - MESSAGE_CREATE: Routes messages to the appropriate Channel.Server
  - READY: Logs when the bot is ready
  - Other events are ignored
  """
  def handle_event({:MESSAGE_CREATE, message, _ws_state}) do
    # Ignore bot messages to prevent loops
    if message.author.bot do
      :noop
    else
      # Route to channel server based on channel_id
      channel_id = "discord:#{message.channel_id}"

      case Registry.lookup(BeamClaw.Registry, {:channel, channel_id}) do
        [{_pid, _}] ->
          BeamClaw.Channel.Server.handle_inbound(channel_id, message)

        [] ->
          Logger.debug(
            "No channel server registered for #{channel_id}, ignoring message from #{message.author.username}"
          )
      end
    end
  end

  def handle_event({:READY, _data, _ws_state}) do
    Logger.info("Discord bot is ready!")
  end

  def handle_event(_event) do
    :noop
  end
end
