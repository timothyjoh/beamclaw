defmodule BeamClaw.Cron.Store do
  @moduledoc """
  JSONL persistence for cron jobs.

  Stores per-agent job definitions in JSONL format:
  - One JSON object per line
  - Each line is a complete job definition
  - Atomic writes using temp file + rename

  ## File Format

  ```jsonl
  {"job_id":"daily-check","type":"main","schedule":{"type":"every","value_ms":86400000,"anchor_ms":0},"prompt":"Check system status","enabled":true,"consecutive_errors":0}
  {"job_id":"morning-report","type":"isolated","schedule":{"type":"cron","expr":"0 9 * * *","tz":"UTC"},"prompt":"Generate morning report","enabled":true,"consecutive_errors":0}
  ```

  ## File Location

  Jobs are stored in `~/.config/beamclaw/data/cron/` by default.
  The data directory can be configured via `BeamClaw.Config`.
  """

  require Logger

  @doc """
  Returns the path to the jobs file for an agent.

  ## Examples

      iex> jobs_path("default")
      "/Users/user/.config/beamclaw/data/cron/default.cron.jsonl"
  """
  def jobs_path(agent_id) do
    data_dir = BeamClaw.Config.get(:data_dir)
    cron_dir = Path.join(data_dir, "cron")
    filename = "#{agent_id}.cron.jsonl"
    Path.join(cron_dir, filename)
  end

  @doc """
  Save all jobs atomically using temp file + rename.

  ## Examples

      iex> jobs = %{
      ...>   "job1" => %{type: :main, schedule: %{type: :at, value: 123}, prompt: "Test", enabled: true, consecutive_errors: 0}
      ...> }
      iex> save_jobs("default", jobs)
      :ok
  """
  def save_jobs(agent_id, jobs) when is_map(jobs) do
    path = jobs_path(agent_id)

    # Ensure directory exists
    ensure_dir(path)

    # Serialize jobs to JSONL
    lines =
      jobs
      |> Enum.map(fn {job_id, job} ->
        job
        |> Map.put(:job_id, job_id)
        |> encode_job()
      end)
      |> Enum.join("\n")

    # Add trailing newline if jobs exist
    content = if lines == "", do: "", else: lines <> "\n"

    # Write to temp file
    temp_path = path <> ".tmp"

    case File.write(temp_path, content) do
      :ok ->
        # Atomic rename
        case File.rename(temp_path, path) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error("Failed to rename #{temp_path} to #{path}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to write temp jobs file #{temp_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Load jobs from JSONL file.

  Returns a map of %{job_id => job_map} or empty map if file doesn't exist.

  ## Examples

      iex> load_jobs("default")
      %{
        "job1" => %{type: :main, schedule: %{...}, prompt: "Test", enabled: true, consecutive_errors: 0}
      }
  """
  def load_jobs(agent_id) do
    path = jobs_path(agent_id)

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(&decode_job/1)
      |> Enum.reduce(%{}, fn
        {:ok, job_id, job}, acc -> Map.put(acc, job_id, job)
        {:error, _reason}, acc -> acc
      end)
    else
      %{}
    end
  end

  @doc """
  Ensures the parent directory of a file path exists.
  """
  def ensure_dir(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()
  end

  # Private Helpers

  defp encode_job(job) do
    # Convert atoms to strings for JSON
    job_map = %{
      job_id: job[:job_id] || job.job_id,
      type: to_string(job[:type] || job.type),
      schedule: encode_schedule(job[:schedule] || job.schedule),
      prompt: job[:prompt] || job.prompt,
      enabled: job[:enabled] || job.enabled,
      consecutive_errors: job[:consecutive_errors] || job.consecutive_errors || 0
    }

    Jason.encode!(job_map)
  end

  defp encode_schedule(%{type: type} = schedule) do
    Map.put(schedule, :type, to_string(type))
  end

  defp decode_job(line) do
    case Jason.decode(line) do
      {:ok, %{"job_id" => job_id} = job_data} ->
        job = %{
          type: String.to_existing_atom(job_data["type"]),
          schedule: decode_schedule(job_data["schedule"]),
          prompt: job_data["prompt"],
          enabled: job_data["enabled"],
          consecutive_errors: job_data["consecutive_errors"] || 0,
          running_at_ms: nil,
          next_run_ms: nil
        }

        {:ok, job_id, job}

      {:ok, _invalid} ->
        {:error, :missing_job_id}

      {:error, reason} ->
        Logger.warning("Failed to decode JSONL line: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp decode_schedule(%{"type" => "at"} = schedule) do
    %{type: :at, value: schedule["value"]}
  end

  defp decode_schedule(%{"type" => "every"} = schedule) do
    %{
      type: :every,
      value_ms: schedule["value_ms"],
      anchor_ms: schedule["anchor_ms"]
    }
  end

  defp decode_schedule(%{"type" => "cron"} = schedule) do
    %{
      type: :cron,
      expr: schedule["expr"],
      tz: schedule["tz"]
    }
  end
end
