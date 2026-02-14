defmodule BeamClaw.Cron.Worker do
  @moduledoc """
  GenServer that manages cron jobs for a single agent.

  Each worker:
  - Is registered in BeamClaw.Registry as {:cron, agent_id}
  - Is started under BeamClaw.CronSupervisor
  - Manages a collection of scheduled jobs
  - Persists jobs to JSONL on disk

  ## Job Types

  - `:main` — Executes in the main session (agent:{agent_id}:main)
  - `:isolated` — Creates an ephemeral session, runs job, cleans up after 24h

  ## Schedule Types

  - `%{type: :at, value: unix_ms}` — One-shot at specific time
  - `%{type: :every, value_ms: interval, anchor_ms: start_time}` — Recurring interval
  - `%{type: :cron, expr: "0 * * * *", tz: "UTC"}` — Cron expression
  """

  use GenServer
  require Logger

  alias BeamClaw.Cron.{Schedule, Store}

  defstruct [:agent_id, jobs: %{}, timer_ref: nil]

  # Two hours in milliseconds for stuck run detection
  @stuck_threshold_ms 2 * 60 * 60 * 1000

  # Client API

  @doc """
  Starts a worker GenServer for an agent.

  Options:
  - `agent_id` (required) - Agent identifier
  """
  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    GenServer.start_link(__MODULE__, opts, name: via(agent_id))
  end

  @doc """
  Adds a new job to the worker.

  Job map must include:
  - `:type` — :main or :isolated
  - `:schedule` — Schedule map
  - `:prompt` — Text to send when job runs
  - `:enabled` (optional, defaults to true)
  """
  def add_job(agent_id, job_id, job) do
    GenServer.call(via(agent_id), {:add_job, job_id, job})
  end

  @doc """
  Removes a job from the worker.
  """
  def remove_job(agent_id, job_id) do
    GenServer.call(via(agent_id), {:remove_job, job_id})
  end

  @doc """
  Lists all jobs for the worker.

  Returns a map of %{job_id => job}.
  """
  def list_jobs(agent_id) do
    GenServer.call(via(agent_id), :list_jobs)
  end

  @doc """
  Manually triggers a job to run immediately.
  """
  def trigger_job(agent_id, job_id) do
    GenServer.cast(via(agent_id), {:trigger_job, job_id})
  end

  @doc """
  Enables a disabled job.
  """
  def enable_job(agent_id, job_id) do
    GenServer.call(via(agent_id), {:enable_job, job_id})
  end

  @doc """
  Disables an enabled job.
  """
  def disable_job(agent_id, job_id) do
    GenServer.call(via(agent_id), {:disable_job, job_id})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)

    # Load jobs from disk
    jobs = Store.load_jobs(agent_id)

    # Compute next runs for all jobs
    now_ms = System.system_time(:millisecond)
    jobs = compute_all_next_runs(jobs, now_ms)

    state = %__MODULE__{
      agent_id: agent_id,
      jobs: jobs,
      timer_ref: nil
    }

    # Schedule the first tick
    state = schedule_next_tick(state)

    Logger.info("Cron worker started for agent: #{agent_id}")
    {:ok, state}
  end

  @impl true
  def handle_call({:add_job, job_id, job}, _from, state) do
    # Normalize job structure
    normalized_job = %{
      type: job[:type] || job.type,
      schedule: job[:schedule] || job.schedule,
      prompt: job[:prompt] || job.prompt,
      enabled: Map.get(job, :enabled, true),
      consecutive_errors: 0,
      running_at_ms: nil,
      next_run_ms: nil
    }

    # Compute next run
    now_ms = System.system_time(:millisecond)
    next_run_ms = compute_next_run(normalized_job.schedule, now_ms)
    normalized_job = %{normalized_job | next_run_ms: next_run_ms}

    # Add to jobs map
    jobs = Map.put(state.jobs, job_id, normalized_job)

    # Persist to disk
    Store.save_jobs(state.agent_id, jobs)

    # Reschedule timer
    state = %{state | jobs: jobs}
    state = schedule_next_tick(state)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:remove_job, job_id}, _from, state) do
    jobs = Map.delete(state.jobs, job_id)

    # Persist to disk
    Store.save_jobs(state.agent_id, jobs)

    # Reschedule timer
    state = %{state | jobs: jobs}
    state = schedule_next_tick(state)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_jobs, _from, state) do
    {:reply, state.jobs, state}
  end

  @impl true
  def handle_call({:enable_job, job_id}, _from, state) do
    case Map.get(state.jobs, job_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      job ->
        # Enable and recompute next run
        now_ms = System.system_time(:millisecond)
        next_run_ms = compute_next_run(job.schedule, now_ms)
        updated_job = %{job | enabled: true, next_run_ms: next_run_ms, consecutive_errors: 0}

        jobs = Map.put(state.jobs, job_id, updated_job)
        Store.save_jobs(state.agent_id, jobs)

        state = %{state | jobs: jobs}
        state = schedule_next_tick(state)

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:disable_job, job_id}, _from, state) do
    case Map.get(state.jobs, job_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      job ->
        updated_job = %{job | enabled: false, next_run_ms: nil}

        jobs = Map.put(state.jobs, job_id, updated_job)
        Store.save_jobs(state.agent_id, jobs)

        state = %{state | jobs: jobs}
        state = schedule_next_tick(state)

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:trigger_job, job_id}, state) do
    case Map.get(state.jobs, job_id) do
      nil ->
        Logger.warning("Cannot trigger job #{job_id}: not found")
        {:noreply, state}

      job ->
        # Execute immediately
        state = execute_job(job_id, job, state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    now_ms = System.system_time(:millisecond)

    # Check for stuck runs
    jobs = check_stuck_runs(state.jobs, now_ms)

    # Find all due jobs
    due_jobs =
      jobs
      |> Enum.filter(fn {_id, job} ->
        job.enabled && job.next_run_ms && job.next_run_ms <= now_ms && !job.running_at_ms
      end)

    # Execute all due jobs
    state = %{state | jobs: jobs}

    state =
      Enum.reduce(due_jobs, state, fn {job_id, job}, acc_state ->
        execute_job(job_id, job, acc_state)
      end)

    # Recompute next runs and reschedule
    jobs = compute_all_next_runs(state.jobs, now_ms)
    state = %{state | jobs: jobs}
    state = schedule_next_tick(state)

    {:noreply, state}
  end

  @impl true
  def handle_info({:job_success, job_id}, state) do
    case Map.get(state.jobs, job_id) do
      nil ->
        {:noreply, state}

      job ->
        # Clear running flag and reset error count
        updated_job = %{job | running_at_ms: nil, consecutive_errors: 0}
        jobs = Map.put(state.jobs, job_id, updated_job)
        Store.save_jobs(state.agent_id, jobs)

        Logger.debug("Job #{job_id} completed successfully")
        {:noreply, %{state | jobs: jobs}}
    end
  end

  @impl true
  def handle_info({:job_error, job_id, reason}, state) do
    case Map.get(state.jobs, job_id) do
      nil ->
        {:noreply, state}

      job ->
        # Increment error count
        consecutive_errors = job.consecutive_errors + 1

        # Auto-disable after 3 consecutive errors
        {enabled, next_run_ms} =
          if consecutive_errors >= 3 do
            Logger.warning(
              "Job #{job_id} failed 3 times consecutively, disabling: #{inspect(reason)}"
            )

            {false, nil}
          else
            Logger.warning("Job #{job_id} failed (#{consecutive_errors}/3): #{inspect(reason)}")
            {job.enabled, job.next_run_ms}
          end

        updated_job = %{
          job
          | running_at_ms: nil,
            consecutive_errors: consecutive_errors,
            enabled: enabled,
            next_run_ms: next_run_ms
        }

        jobs = Map.put(state.jobs, job_id, updated_job)
        Store.save_jobs(state.agent_id, jobs)

        state = %{state | jobs: jobs}
        state = schedule_next_tick(state)

        {:noreply, state}
    end
  end

  # Private Helpers

  defp via(agent_id) do
    {:via, Registry, {BeamClaw.Registry, {:cron, agent_id}}}
  end

  defp schedule_next_tick(state) do
    # Cancel existing timer
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    # Find earliest next run among enabled jobs
    now_ms = System.system_time(:millisecond)

    earliest_run =
      state.jobs
      |> Enum.filter(fn {_id, job} -> job.enabled && job.next_run_ms end)
      |> Enum.map(fn {_id, job} -> job.next_run_ms end)
      |> Enum.min(fn -> nil end)

    timer_ref =
      if earliest_run do
        delay = max(0, earliest_run - now_ms)
        Process.send_after(self(), :tick, delay)
      else
        nil
      end

    %{state | timer_ref: timer_ref}
  end

  defp compute_all_next_runs(jobs, now_ms) do
    Map.new(jobs, fn {id, job} ->
      if job.enabled do
        next_run_ms = compute_next_run(job.schedule, now_ms)
        {id, %{job | next_run_ms: next_run_ms}}
      else
        {id, job}
      end
    end)
  end

  defp compute_next_run(schedule, now_ms) do
    Schedule.compute_next_run(schedule, now_ms)
  end

  defp check_stuck_runs(jobs, now_ms) do
    Map.new(jobs, fn {id, job} ->
      if job.running_at_ms && now_ms - job.running_at_ms > @stuck_threshold_ms do
        Logger.warning("Job #{id} stuck for >2 hours, clearing running flag")
        {id, %{job | running_at_ms: nil}}
      else
        {id, job}
      end
    end)
  end

  defp execute_job(job_id, job, state) do
    # Mark as running
    now_ms = System.system_time(:millisecond)
    updated_job = %{job | running_at_ms: now_ms}
    jobs = Map.put(state.jobs, job_id, updated_job)

    # Spawn async execution
    parent = self()

    Task.start(fn ->
      try do
        case job.type do
          :main ->
            execute_main_job(state.agent_id, job, parent, job_id)

          :isolated ->
            execute_isolated_job(state.agent_id, job, parent, job_id)
        end
      rescue
        error ->
          send(parent, {:job_error, job_id, error})
      end
    end)

    %{state | jobs: jobs}
  end

  defp execute_main_job(agent_id, job, parent, job_id) do
    session_key = "agent:#{agent_id}:main"

    # Check if main session exists
    case Registry.lookup(BeamClaw.Registry, {:session, session_key}) do
      [{_pid, _}] ->
        # Session exists, send message
        BeamClaw.Session.send_message(session_key, job.prompt)
        send(parent, {:job_success, job_id})

      [] ->
        # Session doesn't exist, create it first
        case DynamicSupervisor.start_child(
               BeamClaw.SessionSupervisor,
               {BeamClaw.Session, session_key: session_key}
             ) do
          {:ok, _pid} ->
            BeamClaw.Session.send_message(session_key, job.prompt)
            send(parent, {:job_success, job_id})

          {:error, reason} ->
            send(parent, {:job_error, job_id, {:session_start_failed, reason}})
        end
    end
  end

  defp execute_isolated_job(agent_id, job, parent, job_id) do
    # Create ephemeral session
    timestamp = System.system_time(:millisecond)
    session_key = "agent:#{agent_id}:cron-#{job_id}-#{timestamp}"

    case DynamicSupervisor.start_child(
           BeamClaw.SessionSupervisor,
           {BeamClaw.Session, session_key: session_key}
         ) do
      {:ok, session_pid} ->
        # Send message to session
        BeamClaw.Session.send_message(session_key, job.prompt)

        # Schedule cleanup after 24 hours
        cleanup_delay = 24 * 60 * 60 * 1000

        Task.start(fn ->
          Process.sleep(cleanup_delay)

          if Process.alive?(session_pid) do
            DynamicSupervisor.terminate_child(BeamClaw.SessionSupervisor, session_pid)
          end
        end)

        send(parent, {:job_success, job_id})

      {:error, reason} ->
        send(parent, {:job_error, job_id, {:session_start_failed, reason}})
    end
  end
end
