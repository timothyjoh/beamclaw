defmodule BeamClaw.Tool.Approval do
  @moduledoc """
  Tool approval flow with ask modes and PubSub-based approval requests.

  Supports three ask modes:
  - `:off` - no approval needed, always approved
  - `:on_miss` - check allowlist first, request approval only if not in allowlist
  - `:always` - always request approval regardless

  Uses ETS to track pending approval requests and Phoenix.PubSub for notifications.
  """

  @table :beamclaw_tool_approvals
  @default_timeout 120_000

  @doc """
  Initialize the approval system by creating the ETS table.

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
  Check if a tool invocation needs approval based on ask mode and allowlist.

  ## Options

    * `:ask_mode` - Approval mode: `:off`, `:on_miss`, or `:always`
    * `:allowlist` - List of tool name patterns (strings)
    * `:session_key` - Session key for approval routing

  ## Returns

    * `:approved` - No approval needed, proceed with execution
    * `{:needs_approval, approval_id}` - Approval required, use this ID to request approval
    * `:denied` - Request denied (currently unused, for future extension)

  ## Examples

      iex> check("exec", %{"command" => "ls"}, ask_mode: :off)
      :approved

      iex> check("exec", %{}, ask_mode: :on_miss, allowlist: ["exec", "web_fetch"])
      :approved

      iex> check("dangerous", %{}, ask_mode: :always, session_key: "agent:default:main")
      {:needs_approval, "approval-123456"}
  """
  @spec check(String.t(), map(), keyword()) :: :approved | {:needs_approval, String.t()} | :denied
  def check(tool_name, _args, opts) when is_binary(tool_name) do
    ask_mode = Keyword.get(opts, :ask_mode, :off)
    allowlist = Keyword.get(opts, :allowlist, [])

    case ask_mode do
      :off ->
        :approved

      :on_miss ->
        if tool_in_allowlist?(tool_name, allowlist) do
          :approved
        else
          approval_id = generate_approval_id()
          {:needs_approval, approval_id}
        end

      :always ->
        approval_id = generate_approval_id()
        {:needs_approval, approval_id}
    end
  end

  @doc """
  Request approval for a tool invocation.

  Broadcasts an approval request on PubSub and blocks waiting for a response.

  ## Arguments

    * `approval_id` - Unique approval ID from check/3
    * `tool_name` - Name of the tool being invoked
    * `args` - Tool arguments map
    * `session_key` - Session key for routing
    * `timeout` - Maximum wait time in milliseconds (default: 120,000)

  ## Returns

    * `:approved` - Request approved
    * `:denied` - Request denied
    * `{:error, :timeout}` - No response within timeout

  ## Examples

      iex> request_approval("approval-123", "exec", %{"command" => "rm -rf /"}, "agent:default:main")
      :denied
  """
  @spec request_approval(String.t(), String.t(), map(), String.t(), integer()) ::
          :approved | :denied | {:error, :timeout}
  def request_approval(approval_id, tool_name, args, session_key, timeout \\ @default_timeout) do
    # Store pending approval in ETS
    entry = {approval_id, self(), tool_name, args, session_key, DateTime.utc_now()}
    :ets.insert(@table, entry)

    # Broadcast approval request on PubSub
    topic = "approval:#{session_key}"
    message = {:approval_request, %{
      id: approval_id,
      tool: tool_name,
      args: args,
      session_key: session_key
    }}

    Phoenix.PubSub.broadcast(BeamClaw.PubSub, topic, message)

    # Block waiting for response
    result = receive do
      {:approval_response, ^approval_id, decision} when decision in [:approved, :denied] ->
        decision
    after
      timeout ->
        {:error, :timeout}
    end

    # Clean up ETS entry
    :ets.delete(@table, approval_id)

    result
  end

  @doc """
  Respond to a pending approval request.

  ## Arguments

    * `approval_id` - The approval ID to respond to
    * `decision` - Either `:approved` or `:denied`

  ## Returns

    * `:ok` - Response sent successfully
    * `{:error, :not_found}` - No pending approval with this ID

  ## Examples

      iex> respond("approval-123", :approved)
      :ok

      iex> respond("nonexistent", :denied)
      {:error, :not_found}
  """
  @spec respond(String.t(), :approved | :denied) :: :ok | {:error, :not_found}
  def respond(approval_id, decision) when decision in [:approved, :denied] do
    case :ets.lookup(@table, approval_id) do
      [{^approval_id, pid, _tool, _args, _session, _timestamp}] ->
        # Send response to waiting process
        send(pid, {:approval_response, approval_id, decision})
        # Clean up ETS entry
        :ets.delete(@table, approval_id)
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  List all pending approval requests.

  ## Returns

  A list of maps with pending approval details:
    * `:id` - Approval ID
    * `:tool` - Tool name
    * `:args` - Tool arguments
    * `:session_key` - Session key
    * `:timestamp` - When the request was created

  ## Examples

      iex> list_pending()
      [%{id: "approval-123", tool: "exec", args: %{}, session_key: "agent:default:main", ...}]
  """
  @spec list_pending() :: [map()]
  def list_pending do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {id, _pid, tool, args, session_key, timestamp} ->
      %{
        id: id,
        tool: tool,
        args: args,
        session_key: session_key,
        timestamp: timestamp
      }
    end)
  end

  ## Private Functions

  defp generate_approval_id do
    "approval-#{:erlang.unique_integer([:positive])}"
  end

  defp tool_in_allowlist?(tool_name, allowlist) do
    Enum.any?(allowlist, fn pattern ->
      # Simple pattern matching - exact match or wildcard
      cond do
        pattern == tool_name -> true
        String.ends_with?(pattern, "*") ->
          prefix = String.trim_trailing(pattern, "*")
          String.starts_with?(tool_name, prefix)
        true -> false
      end
    end)
  end
end
