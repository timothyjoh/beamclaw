defmodule BeamClaw.Tool.Exec do
  @moduledoc """
  Execute shell commands with security controls and background process support.

  Commands run with a yield timeout of 10 seconds. If they complete within that time,
  the full output and exit code are returned. If still running, the process is
  backgrounded and registered in BackgroundProcessRegistry.
  """

  alias BeamClaw.BackgroundProcessRegistry

  @blocked_env ~w[LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES NODE_OPTIONS
                  PYTHONPATH RUBYLIB PERL5LIB PATH HOME USER SHELL]

  @yield_timeout 10_000  # 10 seconds
  @max_output 200_000    # 200KB

  @type exec_opts :: [
    command: String.t(),
    working_dir: String.t(),
    env: map(),
    timeout: integer(),
    security_mode: :gateway | :sandbox | :node
  ]

  @doc """
  Execute a shell command.

  ## Options

    * `:command` - The shell command to execute (required)
    * `:working_dir` - Working directory for the command (defaults to current directory)
    * `:env` - Additional environment variables as a map
    * `:timeout` - Maximum execution time in milliseconds
    * `:security_mode` - Security mode: `:gateway` (default), `:sandbox`, or `:node`

  ## Returns

    * `{:ok, %{output: text, exit_code: int}}` - Completed within yield timeout
    * `{:ok, %{output: text, backgrounded: true, slug: slug}}` - Still running, backgrounded
    * `{:error, reason}` - Execution failed

  ## Examples

      iex> Exec.run("echo hello")
      {:ok, %{output: "hello\\n", exit_code: 0}}

      iex> Exec.run("sleep 15")
      {:ok, %{output: "", backgrounded: true, slug: "exec-123456"}}
  """
  @spec run(String.t(), exec_opts()) :: {:ok, map()} | {:error, term()}
  def run(command, opts \\ []) when is_binary(command) do
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    env = Keyword.get(opts, :env, %{})
    security_mode = Keyword.get(opts, :security_mode, :gateway)

    # Emit telemetry start event
    start_time = System.monotonic_time()
    metadata = %{command: command, security_mode: security_mode}
    BeamClaw.Telemetry.emit_tool_execute_start(metadata)

    # Sanitize environment variables based on security mode
    sanitized_env = sanitize_env(env, security_mode)

    # Get shell executable
    shell = System.find_executable("sh") || "/bin/sh"

    # Build port options
    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: ["-c", command],
      cd: String.to_charlist(working_dir)
    ]

    port_opts = if sanitized_env != [], do: port_opts ++ [env: sanitized_env], else: port_opts

    result =
      try do
        # Open the port
        port = Port.open({:spawn_executable, String.to_charlist(shell)}, port_opts)

        # Get OS PID
        os_pid = get_os_pid(port)

        # Collect output with yield timeout
        case collect_output(port, os_pid, command, @yield_timeout) do
          {:completed, output, exit_code} ->
            {:ok, %{output: truncate_output(output), exit_code: exit_code}}

          {:timeout, partial_output} ->
            # Background the process
            slug = generate_slug()
            BackgroundProcessRegistry.register(slug, port, os_pid, command)

            # Start monitoring task to collect remaining output
            start_background_monitor(slug, port)

            {:ok, %{output: truncate_output(partial_output), backgrounded: true, slug: slug}}
        end
      rescue
        e ->
          {:error, "#{Exception.message(e)} - #{inspect(__STACKTRACE__)}"}
      end

    # Emit telemetry stop/exception event
    duration = System.monotonic_time() - start_time

    case result do
      {:ok, %{exit_code: code}} when code == 0 ->
        BeamClaw.Telemetry.emit_tool_execute_stop(%{duration: duration}, Map.put(metadata, :exit_code, code))

      {:ok, %{backgrounded: true}} ->
        BeamClaw.Telemetry.emit_tool_execute_stop(%{duration: duration}, Map.put(metadata, :backgrounded, true))

      {:ok, %{exit_code: code}} ->
        BeamClaw.Telemetry.emit_tool_execute_exception(%{duration: duration}, Map.put(metadata, :exit_code, code))

      {:error, _reason} ->
        BeamClaw.Telemetry.emit_tool_execute_exception(%{duration: duration}, metadata)
    end

    result
  end

  ## Private Functions

  defp sanitize_env(env, mode) do
    case mode do
      :gateway ->
        env
        |> Enum.reject(fn {key, _} -> key in @blocked_env end)
        |> Enum.map(fn {k, v} ->
          {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
        end)

      :sandbox ->
        # Docker handles env - return empty list
        []

      :node ->
        # Remote node handles env - return empty list
        []
    end
  end

  defp get_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp collect_output(port, os_pid, command, timeout) do
    start_time = System.monotonic_time(:millisecond)
    do_collect_output(port, os_pid, command, "", start_time, timeout)
  end

  defp do_collect_output(port, os_pid, command, acc, start_time, timeout) do
    elapsed = System.monotonic_time(:millisecond) - start_time
    remaining = max(0, timeout - elapsed)

    receive do
      {^port, {:data, data}} ->
        new_acc = acc <> data
        do_collect_output(port, os_pid, command, new_acc, start_time, timeout)

      {^port, {:exit_status, status}} ->
        # Port might already be closed, so ignore errors
        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end

        {:completed, acc, status}
    after
      remaining ->
        # Timeout - process still running
        {:timeout, acc}
    end
  end

  defp truncate_output(output) when byte_size(output) <= @max_output, do: output

  defp truncate_output(output) do
    # Keep last 200KB
    binary_part(output, byte_size(output) - @max_output, @max_output)
  end

  defp generate_slug do
    "exec-#{:erlang.unique_integer([:positive, :monotonic])}"
  end

  defp start_background_monitor(slug, port) do
    Task.Supervisor.start_child(BeamClaw.ToolSupervisor, fn ->
      monitor_background_process(slug, port)
    end)
  end

  defp monitor_background_process(slug, port) do
    receive do
      {^port, {:data, data}} ->
        BackgroundProcessRegistry.update_output(slug, data)
        monitor_background_process(slug, port)

      {^port, {:exit_status, status}} ->
        BackgroundProcessRegistry.mark_exited(slug, status)

        # Port might already be closed, so ignore errors
        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end

        :ok
    end
  end
end
