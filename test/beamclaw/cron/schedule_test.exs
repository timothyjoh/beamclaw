defmodule BeamClaw.Cron.ScheduleTest do
  use ExUnit.Case, async: true

  alias BeamClaw.Cron.Schedule

  describe "compute_next_run/2 with :at schedule" do
    test "returns value when in future" do
      now_ms = System.system_time(:millisecond)
      future_ms = now_ms + 10_000

      schedule = %{type: :at, value: future_ms}
      assert Schedule.compute_next_run(schedule, now_ms) == future_ms
    end

    test "returns nil when in past" do
      now_ms = System.system_time(:millisecond)
      past_ms = now_ms - 10_000

      schedule = %{type: :at, value: past_ms}
      assert Schedule.compute_next_run(schedule, now_ms) == nil
    end

    test "returns nil when exactly now" do
      now_ms = System.system_time(:millisecond)

      schedule = %{type: :at, value: now_ms}
      assert Schedule.compute_next_run(schedule, now_ms) == nil
    end
  end

  describe "compute_next_run/2 with :every schedule" do
    test "computes next run with interval from anchor" do
      anchor_ms = 1_000_000
      interval_ms = 60_000
      now_ms = anchor_ms + 150_000

      schedule = %{type: :every, value_ms: interval_ms, anchor_ms: anchor_ms}

      # Elapsed: 150_000, ticks: 2 (120_000), next: 3 * 60_000 = 180_000
      expected = anchor_ms + 180_000
      assert Schedule.compute_next_run(schedule, now_ms) == expected
    end

    test "returns anchor when now is before anchor" do
      anchor_ms = 1_000_000
      interval_ms = 60_000
      now_ms = anchor_ms - 10_000

      schedule = %{type: :every, value_ms: interval_ms, anchor_ms: anchor_ms}
      assert Schedule.compute_next_run(schedule, now_ms) == anchor_ms
    end

    test "handles exact tick boundary" do
      anchor_ms = 0
      interval_ms = 100
      now_ms = 300

      schedule = %{type: :every, value_ms: interval_ms, anchor_ms: anchor_ms}

      # At exact tick 300, next should be 400
      assert Schedule.compute_next_run(schedule, now_ms) == 400
    end

    test "computes next hourly run" do
      anchor_ms = 0
      interval_ms = 3_600_000
      now_ms = System.system_time(:millisecond)

      schedule = %{type: :every, value_ms: interval_ms, anchor_ms: anchor_ms}
      next_run = Schedule.compute_next_run(schedule, now_ms)

      assert is_integer(next_run)
      assert next_run > now_ms
      assert next_run - now_ms <= interval_ms
    end
  end

  describe "compute_next_run/2 with :cron schedule" do
    test "computes next run for hourly cron" do
      schedule = %{type: :cron, expr: "0 * * * *", tz: "UTC"}
      now_ms = System.system_time(:millisecond)

      next_run_ms = Schedule.compute_next_run(schedule, now_ms)

      assert is_integer(next_run_ms)
      assert next_run_ms > now_ms

      # Should be within the next hour
      assert next_run_ms - now_ms <= 3_600_000
    end

    test "computes next run for daily cron at 9am" do
      schedule = %{type: :cron, expr: "0 9 * * *", tz: "UTC"}
      now_ms = System.system_time(:millisecond)

      next_run_ms = Schedule.compute_next_run(schedule, now_ms)

      assert is_integer(next_run_ms)
      assert next_run_ms > now_ms

      # Should be within the next 24 hours
      assert next_run_ms - now_ms <= 24 * 3_600_000
    end

    test "returns nil for invalid cron expression" do
      schedule = %{type: :cron, expr: "invalid", tz: "UTC"}
      now_ms = System.system_time(:millisecond)

      assert Schedule.compute_next_run(schedule, now_ms) == nil
    end

    test "handles timezone conversion" do
      schedule = %{type: :cron, expr: "0 0 * * *", tz: "America/New_York"}
      now_ms = System.system_time(:millisecond)

      next_run_ms = Schedule.compute_next_run(schedule, now_ms)

      assert is_integer(next_run_ms)
      assert next_run_ms > now_ms
    end
  end
end
