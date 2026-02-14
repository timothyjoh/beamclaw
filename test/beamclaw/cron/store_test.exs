defmodule BeamClaw.Cron.StoreTest do
  use ExUnit.Case, async: true

  alias BeamClaw.Cron.Store

  setup do
    # Use unique agent ID for test isolation
    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    # Clean up test file after each test
    path = Store.jobs_path(agent_id)

    on_exit(fn ->
      if File.exists?(path) do
        File.rm(path)
      end
    end)

    %{agent_id: agent_id}
  end

  describe "jobs_path/1" do
    test "returns correct path for agent", %{agent_id: agent_id} do
      path = Store.jobs_path(agent_id)
      assert String.ends_with?(path, "#{agent_id}.cron.jsonl")
      assert path =~ "/cron/"
    end
  end

  describe "save_jobs/2 and load_jobs/1" do
    test "round-trip saves and loads jobs", %{agent_id: agent_id} do
      jobs = %{
        "job1" => %{
          type: :main,
          schedule: %{type: :at, value: 123_456_789},
          prompt: "Test job 1",
          enabled: true,
          consecutive_errors: 0,
          running_at_ms: nil,
          next_run_ms: nil
        },
        "job2" => %{
          type: :isolated,
          schedule: %{type: :every, value_ms: 60_000, anchor_ms: 0},
          prompt: "Test job 2",
          enabled: false,
          consecutive_errors: 2,
          running_at_ms: nil,
          next_run_ms: nil
        }
      }

      assert Store.save_jobs(agent_id, jobs) == :ok

      loaded_jobs = Store.load_jobs(agent_id)

      assert map_size(loaded_jobs) == 2
      assert loaded_jobs["job1"].type == :main
      assert loaded_jobs["job1"].prompt == "Test job 1"
      assert loaded_jobs["job1"].enabled == true
      assert loaded_jobs["job2"].type == :isolated
      assert loaded_jobs["job2"].enabled == false
      assert loaded_jobs["job2"].consecutive_errors == 2
    end

    test "handles empty jobs map", %{agent_id: agent_id} do
      assert Store.save_jobs(agent_id, %{}) == :ok
      assert Store.load_jobs(agent_id) == %{}
    end

    test "returns empty map when file doesn't exist", %{agent_id: agent_id} do
      assert Store.load_jobs(agent_id) == %{}
    end

    test "preserves schedule structure", %{agent_id: agent_id} do
      jobs = %{
        "cron-job" => %{
          type: :main,
          schedule: %{type: :cron, expr: "0 9 * * *", tz: "UTC"},
          prompt: "Daily report",
          enabled: true,
          consecutive_errors: 0,
          running_at_ms: nil,
          next_run_ms: nil
        }
      }

      Store.save_jobs(agent_id, jobs)
      loaded_jobs = Store.load_jobs(agent_id)

      assert loaded_jobs["cron-job"].schedule.type == :cron
      assert loaded_jobs["cron-job"].schedule.expr == "0 9 * * *"
      assert loaded_jobs["cron-job"].schedule.tz == "UTC"
    end

    test "atomic write using temp file", %{agent_id: agent_id} do
      jobs = %{
        "job1" => %{
          type: :main,
          schedule: %{type: :at, value: 123},
          prompt: "Test",
          enabled: true,
          consecutive_errors: 0,
          running_at_ms: nil,
          next_run_ms: nil
        }
      }

      Store.save_jobs(agent_id, jobs)

      # Verify temp file doesn't exist after save
      path = Store.jobs_path(agent_id)
      temp_path = path <> ".tmp"
      refute File.exists?(temp_path)

      # Verify actual file exists
      assert File.exists?(path)
    end
  end

  describe "ensure_dir/1" do
    test "creates parent directory if it doesn't exist" do
      tmp_dir = System.tmp_dir!()
      test_id = System.unique_integer([:positive])
      nested_path = Path.join([tmp_dir, "beamclaw-test-#{test_id}", "a", "b", "c", "file.txt"])

      Store.ensure_dir(nested_path)

      parent_dir = Path.dirname(nested_path)
      assert File.dir?(parent_dir)

      # Cleanup
      File.rm_rf!(Path.join(tmp_dir, "beamclaw-test-#{test_id}"))
    end

    test "doesn't fail if directory already exists" do
      tmp_dir = System.tmp_dir!()
      path = Path.join(tmp_dir, "file.txt")

      Store.ensure_dir(path)
      Store.ensure_dir(path)

      assert File.dir?(tmp_dir)
    end
  end
end
