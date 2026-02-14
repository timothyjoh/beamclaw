defmodule BeamClaw.Cron.Schedule do
  @moduledoc """
  Schedule parsing and next-run computation for cron jobs.

  Supports three schedule types:
  - `:at` — One-shot execution at a specific timestamp
  - `:every` — Recurring interval-based execution
  - `:cron` — Cron expression with timezone support
  """

  require Logger

  @type schedule ::
          %{type: :at, value: integer()}
          | %{type: :every, value_ms: integer(), anchor_ms: integer()}
          | %{type: :cron, expr: String.t(), tz: String.t()}

  @doc """
  Compute the next run time in Unix milliseconds, or nil if no future run.

  ## Examples

      # One-shot in the future
      iex> future_ms = System.system_time(:millisecond) + 10_000
      iex> schedule = %{type: :at, value: future_ms}
      iex> BeamClaw.Cron.Schedule.compute_next_run(schedule, System.system_time(:millisecond))
      future_ms

      # One-shot in the past
      iex> past_ms = System.system_time(:millisecond) - 10_000
      iex> schedule = %{type: :at, value: past_ms}
      iex> BeamClaw.Cron.Schedule.compute_next_run(schedule, System.system_time(:millisecond))
      nil

      # Every hour
      iex> schedule = %{type: :every, value_ms: 3600_000, anchor_ms: 0}
      iex> is_integer(BeamClaw.Cron.Schedule.compute_next_run(schedule, System.system_time(:millisecond)))
      true
  """
  @spec compute_next_run(schedule(), integer()) :: integer() | nil
  def compute_next_run(%{type: :at, value: value_ms}, now_ms) do
    if value_ms > now_ms do
      value_ms
    else
      nil
    end
  end

  def compute_next_run(%{type: :every, value_ms: interval_ms, anchor_ms: anchor_ms}, now_ms) do
    cond do
      # If now is before anchor, return anchor
      now_ms < anchor_ms ->
        anchor_ms

      # Compute next tick from anchor
      true ->
        elapsed = now_ms - anchor_ms
        ticks_elapsed = div(elapsed, interval_ms)
        next_tick = anchor_ms + (ticks_elapsed + 1) * interval_ms
        next_tick
    end
  end

  def compute_next_run(%{type: :cron, expr: expr, tz: tz}, _now_ms) do
    with {:ok, cron_expr} <- parse_cron_expression(expr),
         {:ok, next_run} <- get_next_cron_run(cron_expr, tz) do
      DateTime.to_unix(next_run, :millisecond)
    else
      {:error, reason} ->
        Logger.warning("Failed to compute next cron run: #{inspect(reason)}")
        nil
    end
  end

  # Private helpers

  defp parse_cron_expression(expr) do
    case Crontab.CronExpression.Parser.parse(expr) do
      {:ok, cron_expr} -> {:ok, cron_expr}
      {:error, reason} -> {:error, {:parse_error, reason}}
    end
  end

  defp get_next_cron_run(cron_expr, _tz) do
    # Use UTC for cron calculations
    # TODO: Add proper timezone support with tz library
    now = DateTime.utc_now()
    naive_now = DateTime.to_naive(now)

    case Crontab.Scheduler.get_next_run_date(cron_expr, naive_now) do
      {:ok, next_naive} ->
        {:ok, DateTime.from_naive!(next_naive, "Etc/UTC")}

      {:error, reason} ->
        {:error, {:scheduler_error, reason}}
    end
  end
end
