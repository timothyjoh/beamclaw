defmodule BeamClaw.BackgroundProcessRegistry do
  @moduledoc """
  Registry for tracking long-running background processes spawned by Tool.Exec.

  Maintains output buffers, process metadata, and handles graceful/forced termination.
  """
  use GenServer
  require Logger

  @max_output_bytes 200_000

  defstruct processes: %{}

  # Process entry structure:
  # %{
  #   port: port(),
  #   os_pid: integer(),
  #   command: String.t(),
  #   started_at: DateTime.t(),
  #   backgrounded_at: DateTime.t(),
  #   output_buffer: String.t(),
  #   exit_status: integer() | nil
  # }

  ## Client API

  @doc """
  Start the registry GenServer.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @doc """
  Register a backgrounded process.
  """
  def register(slug, port, os_pid, command) do
    GenServer.call(__MODULE__, {:register, slug, port, os_pid, command})
  end

  @doc """
  Send input to a process's stdin.
  """
  def send_input(slug, input) do
    GenServer.call(__MODULE__, {:send_input, slug, input})
  end

  @doc """
  Get the last N lines of output from a process.
  """
  def tail_output(slug, lines \\ 50) do
    GenServer.call(__MODULE__, {:tail_output, slug, lines})
  end

  @doc """
  Kill a process (SIGTERM → 5s → SIGKILL if needed).
  """
  def kill(slug) do
    GenServer.cast(__MODULE__, {:kill, slug})
  end

  @doc """
  List all registered processes.
  """
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Get information about a specific process.
  """
  def get(slug) do
    GenServer.call(__MODULE__, {:get, slug})
  end

  @doc """
  Append output data to a process's buffer.
  """
  def update_output(slug, data) do
    GenServer.cast(__MODULE__, {:update_output, slug, data})
  end

  @doc """
  Mark a process as exited with the given exit status.
  """
  def mark_exited(slug, exit_status) do
    GenServer.cast(__MODULE__, {:mark_exited, slug, exit_status})
  end

  ## Server Callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:register, slug, port, os_pid, command}, _from, state) do
    now = DateTime.utc_now()

    entry = %{
      port: port,
      os_pid: os_pid,
      command: command,
      started_at: now,
      backgrounded_at: now,
      output_buffer: "",
      exit_status: nil
    }

    new_processes = Map.put(state.processes, slug, entry)
    {:reply, :ok, %{state | processes: new_processes}}
  end

  @impl true
  def handle_call({:send_input, slug, input}, _from, state) do
    case Map.get(state.processes, slug) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{port: port, exit_status: nil} ->
        Port.command(port, input)
        {:reply, :ok, state}

      _exited ->
        {:reply, {:error, :process_exited}, state}
    end
  end

  @impl true
  def handle_call({:tail_output, slug, lines}, _from, state) do
    case Map.get(state.processes, slug) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{output_buffer: buffer} ->
        lines_list = String.split(buffer, "\n")
        tail_lines = Enum.take(lines_list, -lines)
        {:reply, {:ok, Enum.join(tail_lines, "\n")}, state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    summaries =
      Enum.map(state.processes, fn {slug, entry} ->
        %{
          slug: slug,
          os_pid: entry.os_pid,
          command: entry.command,
          started_at: entry.started_at,
          backgrounded_at: entry.backgrounded_at,
          exit_status: entry.exit_status
        }
      end)

    {:reply, summaries, state}
  end

  @impl true
  def handle_call({:get, slug}, _from, state) do
    case Map.get(state.processes, slug) do
      nil -> {:reply, {:error, :not_found}, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  @impl true
  def handle_cast({:kill, slug}, state) do
    case Map.get(state.processes, slug) do
      nil ->
        {:noreply, state}

      %{os_pid: pid, exit_status: nil} ->
        # Try graceful SIGTERM first
        System.cmd("kill", ["-TERM", "#{pid}"], stderr_to_stdout: true)
        # Schedule force kill if still running after 5s
        Process.send_after(self(), {:force_kill, slug, pid}, 5_000)
        {:noreply, state}

      _already_exited ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:update_output, slug, data}, state) do
    case Map.get(state.processes, slug) do
      nil ->
        {:noreply, state}

      entry ->
        # Append data and cap at max size (circular buffer)
        new_buffer = entry.output_buffer <> data
        new_buffer =
          if byte_size(new_buffer) > @max_output_bytes do
            # Keep last 200KB
            binary_part(new_buffer, byte_size(new_buffer) - @max_output_bytes, @max_output_bytes)
          else
            new_buffer
          end

        updated_entry = %{entry | output_buffer: new_buffer}
        new_processes = Map.put(state.processes, slug, updated_entry)
        {:noreply, %{state | processes: new_processes}}
    end
  end

  @impl true
  def handle_cast({:mark_exited, slug, exit_status}, state) do
    case Map.get(state.processes, slug) do
      nil ->
        {:noreply, state}

      entry ->
        updated_entry = %{entry | exit_status: exit_status}
        new_processes = Map.put(state.processes, slug, updated_entry)
        {:noreply, %{state | processes: new_processes}}
    end
  end

  @impl true
  def handle_info({:force_kill, slug, pid}, state) do
    case Map.get(state.processes, slug) do
      %{exit_status: nil} ->
        # Process still hasn't exited, force kill
        Logger.warning("Force killing process #{slug} (pid #{pid}) after timeout")
        System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)
        {:noreply, state}

      _ ->
        # Already exited, nothing to do
        {:noreply, state}
    end
  end
end
