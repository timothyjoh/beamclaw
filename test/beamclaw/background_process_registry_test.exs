defmodule BeamClaw.BackgroundProcessRegistryTest do
  use ExUnit.Case, async: false

  alias BeamClaw.BackgroundProcessRegistry

  setup do
    # Registry is already started by Application
    # Just ensure we clean up any processes between tests
    :ok
  end

  describe "register/4 and get/1" do
    test "registers a new process" do
      slug = "test-slug-#{:erlang.unique_integer([:positive])}"
      port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "sleep 1"]])
      os_pid = 12345

      assert :ok = BackgroundProcessRegistry.register(slug, port, os_pid, "sleep 1")

      assert {:ok, entry} = BackgroundProcessRegistry.get(slug)
      assert entry.port == port
      assert entry.os_pid == os_pid
      assert entry.command == "sleep 1"
      assert entry.exit_status == nil
      assert entry.output_buffer == ""

      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end

    test "returns error for non-existent process" do
      assert {:error, :not_found} = BackgroundProcessRegistry.get("nonexistent-99999")
    end
  end

  describe "list/0" do
    test "lists all registered processes" do
      slug1 = "slug1-#{:erlang.unique_integer([:positive])}"
      slug2 = "slug2-#{:erlang.unique_integer([:positive])}"

      port1 = Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "sleep 1"]])
      port2 = Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "sleep 2"]])

      BackgroundProcessRegistry.register(slug1, port1, 111, "sleep 1")
      BackgroundProcessRegistry.register(slug2, port2, 222, "sleep 2")

      list = BackgroundProcessRegistry.list()
      slugs = Enum.map(list, & &1.slug)

      assert slug1 in slugs
      assert slug2 in slugs

      try do
        Port.close(port1)
        Port.close(port2)
      rescue
        _ -> :ok
      end
    end

    test "returns list (might have entries from other tests)" do
      # Since registry is shared, just verify we can call list
      list = BackgroundProcessRegistry.list()
      assert is_list(list)
    end
  end

  describe "update_output/2 and tail_output/2" do
    test "appends output to buffer" do
      slug = "test-output-#{:erlang.unique_integer([:positive])}"
      port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "sleep 1"]])
      BackgroundProcessRegistry.register(slug, port, 123, "test")

      BackgroundProcessRegistry.update_output(slug, "line1\n")
      BackgroundProcessRegistry.update_output(slug, "line2\n")

      assert {:ok, output} = BackgroundProcessRegistry.tail_output(slug)
      assert output == "line1\nline2\n"

      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end

    test "tails last N lines" do
      slug = "test-tail-#{:erlang.unique_integer([:positive])}"
      port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "sleep 1"]])
      BackgroundProcessRegistry.register(slug, port, 123, "test")

      BackgroundProcessRegistry.update_output(slug, "line1\nline2\nline3\nline4\nline5")

      assert {:ok, output} = BackgroundProcessRegistry.tail_output(slug, 3)
      lines = String.split(output, "\n", trim: true)
      assert length(lines) >= 2
      assert "line5" in lines

      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end

    test "caps output buffer at 200KB" do
      slug = "test-cap-#{:erlang.unique_integer([:positive])}"
      port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "sleep 1"]])
      BackgroundProcessRegistry.register(slug, port, 123, "test")

      # Add more than 200KB of data
      large_chunk = String.duplicate("X", 100_000)
      BackgroundProcessRegistry.update_output(slug, large_chunk)
      BackgroundProcessRegistry.update_output(slug, large_chunk)
      BackgroundProcessRegistry.update_output(slug, large_chunk)

      {:ok, entry} = BackgroundProcessRegistry.get(slug)
      # Should be capped at 200KB
      assert byte_size(entry.output_buffer) == 200_000

      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end
  end

  describe "mark_exited/2" do
    test "marks process as exited with status" do
      slug = "test-exit-#{:erlang.unique_integer([:positive])}"
      port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "sleep 1"]])
      BackgroundProcessRegistry.register(slug, port, 123, "test")

      BackgroundProcessRegistry.mark_exited(slug, 0)

      assert {:ok, entry} = BackgroundProcessRegistry.get(slug)
      assert entry.exit_status == 0

      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end
  end

  describe "send_input/2" do
    test "sends input to running process" do
      slug = "test-input-#{:erlang.unique_integer([:positive])}"
      port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "cat"]])
      BackgroundProcessRegistry.register(slug, port, 123, "cat")

      assert :ok = BackgroundProcessRegistry.send_input(slug, "hello\n")

      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end

    test "returns error for non-existent process" do
      assert {:error, :not_found} =
               BackgroundProcessRegistry.send_input("nonexistent-#{:erlang.unique_integer([:positive])}", "data")
    end

    test "returns error for exited process" do
      slug = "test-exited-#{:erlang.unique_integer([:positive])}"
      port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "sleep 1"]])
      BackgroundProcessRegistry.register(slug, port, 123, "test")
      BackgroundProcessRegistry.mark_exited(slug, 0)

      assert {:error, :process_exited} = BackgroundProcessRegistry.send_input(slug, "data")

      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end
  end

  describe "kill/1" do
    test "sends SIGTERM to process" do
      slug = "test-kill-#{:erlang.unique_integer([:positive])}"
      # Start a real process that we can kill
      port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "sleep 30"]])
      {:os_pid, os_pid} = Port.info(port, :os_pid)

      BackgroundProcessRegistry.register(slug, port, os_pid, "sleep 30")

      # Kill should succeed
      BackgroundProcessRegistry.kill(slug)

      # Wait a bit for the signal to be sent
      Process.sleep(100)

      # Process should eventually exit
      # (We can't reliably test the exit status here without more complex setup)

      try do
        Port.close(port)
      rescue
        _ -> :ok
      end
    end

    test "handles non-existent process gracefully" do
      # Should not crash
      BackgroundProcessRegistry.kill("nonexistent-#{:erlang.unique_integer([:positive])}")
    end
  end
end
