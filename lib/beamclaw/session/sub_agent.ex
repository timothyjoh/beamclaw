defmodule BeamClaw.Session.SubAgent do
  @moduledoc """
  Manages sub-agent spawning and lifecycle for Session GenServers.

  Sub-agents are child sessions spawned from a parent session for delegated work.
  Key constraints:
  - Maximum depth of 1 (sub-agents cannot spawn their own sub-agents)
  - Each sub-agent runs in its own Session GenServer
  - Parent monitors child processes and tracks their lifecycle
  """

  require Logger

  defstruct [
    :run_id,
    :child_session_key,
    :parent_session_key,
    :child_pid,
    :task,
    :label,
    :cleanup,
    :status,
    :created_at,
    :ended_at,
    :outcome
  ]

  @type cleanup_policy :: :delete | :keep
  @type status :: :running | :completed | :failed

  @type t :: %__MODULE__{
    run_id: String.t(),
    child_session_key: String.t(),
    parent_session_key: String.t(),
    child_pid: pid(),
    task: String.t(),
    label: String.t() | nil,
    cleanup: cleanup_policy(),
    status: status(),
    created_at: DateTime.t(),
    ended_at: DateTime.t() | nil,
    outcome: term()
  }

  @doc """
  Spawns a new sub-agent from a parent session.

  Options:
  - `task` (required) - The task description for the sub-agent
  - `agent_id` (optional) - Agent ID for the child (defaults to parent's agent_id)
  - `label` (optional) - Human-readable label for the run
  - `cleanup` (optional) - :delete (default) or :keep

  Returns `{:ok, %SubAgentRun{}}` or `{:error, reason}`.

  ## Examples

      {:ok, run} = SubAgent.spawn("agent:default:main", task: "Research topic X")
      {:ok, run} = SubAgent.spawn("agent:mybot:conv1",
        task: "Analyze logs",
        label: "Log Analyzer",
        cleanup: :keep
      )
  """
  @spec spawn(String.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def spawn(parent_session_key, opts) do
    # Validate parent session exists
    case lookup_session(parent_session_key) do
      nil ->
        {:error, :parent_not_found}

      parent_pid ->
        # Get parent state to check depth limit
        parent_state = GenServer.call(parent_pid, :get_state)

        # Enforce max depth of 1: if parent has a parent, reject
        if parent_state.parent_session != nil do
          {:error, :sub_agents_cannot_spawn}
        else
          do_spawn(parent_session_key, parent_pid, parent_state, opts)
        end
    end
  end

  defp do_spawn(parent_session_key, parent_pid, parent_state, opts) do
    # Extract options
    task = Keyword.fetch!(opts, :task)
    agent_id = Keyword.get(opts, :agent_id, parent_state.agent_id)
    label = Keyword.get(opts, :label)
    cleanup = Keyword.get(opts, :cleanup, :delete)

    # Generate unique child session key
    unique_id = generate_unique_id()
    child_session_key = "agent:#{agent_id}:subagent:#{unique_id}"

    # Start child session under SessionSupervisor
    child_opts = [
      session_key: child_session_key,
      parent_session: parent_pid
    ]

    case DynamicSupervisor.start_child(
      BeamClaw.SessionSupervisor,
      {BeamClaw.Session, child_opts}
    ) do
      {:ok, child_pid} ->
        # Create SubAgentRun struct
        run = %__MODULE__{
          run_id: unique_id,
          child_session_key: child_session_key,
          parent_session_key: parent_session_key,
          child_pid: child_pid,
          task: task,
          label: label,
          cleanup: cleanup,
          status: :running,
          created_at: DateTime.utc_now(),
          ended_at: nil,
          outcome: nil
        }

        # Add to parent's state (parent will set up the monitor)
        GenServer.call(parent_pid, {:add_sub_agent, run})

        Logger.info("Spawned sub-agent #{unique_id} for parent #{parent_session_key}")
        {:ok, run}

      {:error, reason} ->
        Logger.error("Failed to spawn sub-agent: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Lists all sub-agent runs for a parent session.

  Returns a list of %SubAgentRun{} structs.
  """
  @spec list_runs(String.t()) :: [t()]
  def list_runs(parent_session_key) do
    case lookup_session(parent_session_key) do
      nil -> []
      pid ->
        state = GenServer.call(pid, :get_state)
        state.sub_agents
    end
  end

  @doc """
  Gets a specific sub-agent run by ID.

  Returns %SubAgentRun{} or nil if not found.
  """
  @spec get_run(String.t(), String.t()) :: t() | nil
  def get_run(parent_session_key, run_id) do
    case lookup_session(parent_session_key) do
      nil -> nil
      pid ->
        state = GenServer.call(pid, :get_state)
        Enum.find(state.sub_agents, &(&1.run_id == run_id))
    end
  end

  @doc """
  Cleans up a sub-agent run by stopping the child session and removing it from the parent.

  Returns :ok or {:error, reason}.
  """
  @spec cleanup_run(String.t(), String.t()) :: :ok | {:error, atom()}
  def cleanup_run(parent_session_key, run_id) do
    case lookup_session(parent_session_key) do
      nil ->
        {:error, :parent_not_found}

      parent_pid ->
        state = GenServer.call(parent_pid, :get_state)

        case Enum.find(state.sub_agents, &(&1.run_id == run_id)) do
          nil ->
            {:error, :run_not_found}

          run ->
            # Stop the child session if still alive
            if Process.alive?(run.child_pid) do
              DynamicSupervisor.terminate_child(
                BeamClaw.SessionSupervisor,
                run.child_pid
              )
            end

            # Remove from parent's sub_agents list
            GenServer.call(parent_pid, {:remove_sub_agent, run_id})

            Logger.info("Cleaned up sub-agent #{run_id}")
            :ok
        end
    end
  end

  # Private Helpers

  defp lookup_session(session_key) do
    case Registry.lookup(BeamClaw.Registry, {:session, session_key}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp generate_unique_id do
    # Generate a short unique ID (8 characters)
    :crypto.strong_rand_bytes(4)
    |> Base.encode16(case: :lower)
  end
end
