defmodule BeamClaw.Tool.Registry do
  @moduledoc """
  Tool registration system for tracking available tools per session.

  Each session can register tools with metadata like ask mode and description.
  Uses ETS for fast lookups.
  """

  @table :beamclaw_tool_registry

  @doc """
  Initialize the registry by creating the ETS table.

  Safe to call multiple times - will not error if table already exists.
  """
  def init do
    try do
      :ets.new(@table, [:named_table, :public, :set])
      :ok
    rescue
      ArgumentError -> :ok  # already exists
    end
  end

  @doc """
  Register a tool for a session.

  ## Arguments

    * `session_key` - Session identifier
    * `tool_name` - Tool name (string)
    * `module` - Module implementing the tool
    * `opts` - Optional metadata (keyword list)

  ## Options

    * `:ask_mode` - Approval mode (default: `:off`)
    * `:description` - Human-readable description

  ## Examples

      iex> register("agent:default:main", "exec", BeamClaw.Tool.Exec, ask_mode: :always)
      :ok
  """
  @spec register(String.t(), String.t(), module(), keyword()) :: :ok
  def register(session_key, tool_name, module, opts \\ []) do
    key = {session_key, tool_name}
    :ets.insert(@table, {key, module, opts})
    :ok
  end

  @doc """
  Unregister a tool from a session.

  ## Examples

      iex> unregister("agent:default:main", "exec")
      :ok
  """
  @spec unregister(String.t(), String.t()) :: :ok
  def unregister(session_key, tool_name) do
    key = {session_key, tool_name}
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  List all tools registered for a session.

  ## Returns

  A list of maps with tool details:
    * `:name` - Tool name
    * `:module` - Tool module
    * `:opts` - Tool options/metadata

  ## Examples

      iex> list_tools("agent:default:main")
      [%{name: "exec", module: BeamClaw.Tool.Exec, opts: [ask_mode: :off]}]
  """
  @spec list_tools(String.t()) :: [map()]
  def list_tools(session_key) do
    pattern = {{session_key, :"$1"}, :"$2", :"$3"}

    @table
    |> :ets.match_object(pattern)
    |> Enum.map(fn {{_session_key, tool_name}, module, opts} ->
      %{
        name: tool_name,
        module: module,
        opts: opts
      }
    end)
  end

  @doc """
  Get a specific tool for a session.

  ## Returns

    * `{:ok, tool_map}` - Tool found
    * `{:error, :not_found}` - Tool not registered

  ## Examples

      iex> get_tool("agent:default:main", "exec")
      {:ok, %{name: "exec", module: BeamClaw.Tool.Exec, opts: []}}

      iex> get_tool("agent:default:main", "nonexistent")
      {:error, :not_found}
  """
  @spec get_tool(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_tool(session_key, tool_name) do
    key = {session_key, tool_name}

    case :ets.lookup(@table, key) do
      [{^key, module, opts}] ->
        {:ok, %{name: tool_name, module: module, opts: opts}}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Register default tools for a session.

  Registers:
    * `exec` → BeamClaw.Tool.Exec
    * `web_fetch` → BeamClaw.Tool.WebFetch

  ## Examples

      iex> register_defaults("agent:default:main")
      :ok
  """
  @spec register_defaults(String.t()) :: :ok
  def register_defaults(session_key) do
    register(session_key, "exec", BeamClaw.Tool.Exec, [])
    register(session_key, "web_fetch", BeamClaw.Tool.WebFetch, [])
    :ok
  end
end
