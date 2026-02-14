defmodule BeamClaw.Config do
  @moduledoc """
  Runtime configuration GenServer for BeamClaw.

  Loads configuration from Application environment and system environment variables.
  Provides convenient access to API keys, model defaults, and data directories.

  ## Configuration Keys

  - `:anthropic_api_key` - Anthropic API key from ANTHROPIC_API_KEY env var
  - `:default_model` - Default LLM model (defaults to "claude-sonnet-4-5-20250929")
  - `:default_max_tokens` - Default max tokens for completions (defaults to 8192)
  - `:data_dir` - Data directory for sessions and state (defaults to ~/.config/beamclaw/data)

  ## Usage

      iex> BeamClaw.Config.get(:default_model)
      "claude-sonnet-4-5-20250929"

      iex> BeamClaw.Config.get(:custom_key, "fallback")
      "fallback"

      iex> BeamClaw.Config.get_api_key()
      "sk-ant-..."
  """

  use GenServer
  require Logger

  @default_model "claude-sonnet-4-5-20250929"
  @default_max_tokens 8192

  # Client API

  @doc """
  Starts the Config GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a configuration value by key.

  Returns nil if the key doesn't exist.
  """
  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @doc """
  Gets a configuration value by key with a default fallback.
  """
  def get(key, default) do
    case get(key) do
      nil -> default
      value -> value
    end
  end

  @doc """
  Convenience function to get the Anthropic API key.
  """
  def get_api_key do
    get(:anthropic_api_key)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    config = load_config()
    Logger.info("BeamClaw.Config initialized with keys: #{inspect(Map.keys(config))}")
    {:ok, config}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state, key), state}
  end

  # Private Helpers

  defp load_config do
    %{
      anthropic_api_key: load_anthropic_api_key(),
      default_model: Application.get_env(:beamclaw, :default_model, @default_model),
      default_max_tokens: Application.get_env(:beamclaw, :default_max_tokens, @default_max_tokens),
      data_dir: load_data_dir()
    }
  end

  defp load_anthropic_api_key do
    System.get_env("ANTHROPIC_API_KEY") ||
      Application.get_env(:beamclaw, :anthropic_api_key)
  end

  defp load_data_dir do
    Application.get_env(:beamclaw, :data_dir) ||
      Path.expand("~/.config/beamclaw/data")
  end
end
