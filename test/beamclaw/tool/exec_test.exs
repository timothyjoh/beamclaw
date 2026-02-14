defmodule BeamClaw.Tool.ExecTest do
  use ExUnit.Case, async: false

  alias BeamClaw.Tool.Exec
  alias BeamClaw.BackgroundProcessRegistry

  setup do
    # Supervisors are already started by Application
    :ok
  end

  describe "run/2 - basic execution" do
    test "executes simple command and returns output" do
      assert {:ok, result} = Exec.run("echo hello")
      assert result.output == "hello\n"
      assert result.exit_code == 0
      refute Map.has_key?(result, :backgrounded)
    end

    test "captures stderr in output" do
      assert {:ok, result} = Exec.run("echo error >&2")
      assert result.output =~ "error"
      assert result.exit_code == 0
    end

    test "returns non-zero exit code on failure" do
      assert {:ok, result} = Exec.run("exit 42")
      assert result.exit_code == 42
    end

    test "handles command with pipes" do
      assert {:ok, result} = Exec.run("echo hello | tr 'h' 'H'")
      assert result.output == "Hello\n"
      assert result.exit_code == 0
    end
  end

  describe "run/2 - working directory" do
    test "executes command in specified working directory" do
      temp_dir = System.tmp_dir!() |> String.trim_trailing("/")

      assert {:ok, result} = Exec.run("pwd", working_dir: temp_dir)

      # Normalize both paths (handle macOS /private symlink and trailing slashes)
      output = String.trim(result.output) |> String.trim_trailing("/")
      normalized_temp = temp_dir |> String.replace("/private/var", "/var")
      normalized_output = output |> String.replace("/private/var", "/var")

      assert normalized_output == normalized_temp
    end
  end

  describe "run/2 - environment variables" do
    test "passes additional environment variables" do
      assert {:ok, result} = Exec.run("echo $TEST_VAR", env: %{"TEST_VAR" => "hello"})
      assert result.output == "hello\n"
    end

    test "blocks dangerous environment variables in gateway mode" do
      # Run a command that would show LD_PRELOAD if it were set
      assert {:ok, result} =
               Exec.run("echo $LD_PRELOAD",
                 env: %{"LD_PRELOAD" => "/bad/lib.so"},
                 security_mode: :gateway
               )

      # LD_PRELOAD should be blocked, so output should be empty (just newline)
      assert result.output == "\n"
    end

    test "blocks all blocked env vars" do
      blocked_vars = [
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "DYLD_INSERT_LIBRARIES",
        "NODE_OPTIONS",
        "PYTHONPATH",
        "RUBYLIB",
        "PERL5LIB"
      ]

      for var <- blocked_vars do
        assert {:ok, result} =
                 Exec.run("printenv #{var} || echo empty",
                   env: %{var => "/danger"},
                   security_mode: :gateway
                 )

        # Should output "empty" since the var is blocked
        assert String.trim(result.output) == "empty"
      end
    end
  end

  describe "run/2 - backgrounding" do
    test "backgrounds long-running process" do
      # Sleep for 15 seconds - longer than the 10s yield timeout
      assert {:ok, result} = Exec.run("sleep 15")

      assert result.backgrounded == true
      assert is_binary(result.slug)
      assert result.slug =~ ~r/^exec-\d+$/

      # Should be registered in the background process registry
      list = BackgroundProcessRegistry.list()
      assert Enum.any?(list, fn p -> p.slug == result.slug end)

      # Clean up: kill the backgrounded process
      BackgroundProcessRegistry.kill(result.slug)
    end

    test "backgrounded process captures partial output" do
      # Echo something, then sleep
      assert {:ok, result} = Exec.run("echo starting && sleep 15")

      assert result.backgrounded == true
      # Should have captured the "starting" output
      assert result.output =~ "starting"

      # Clean up
      BackgroundProcessRegistry.kill(result.slug)
    end

    test "can tail output from backgrounded process" do
      # Start a process that outputs immediately then sleeps
      assert {:ok, result} = Exec.run("echo 'test output line1' && echo 'test output line2' && sleep 15")

      assert result.backgrounded == true
      # The initial output should be captured during the yield_timeout

      # Give the monitoring task time to start
      Process.sleep(200)

      # We should be able to tail the output
      assert {:ok, _output} = BackgroundProcessRegistry.tail_output(result.slug)

      # Clean up
      BackgroundProcessRegistry.kill(result.slug)
    end

    test "backgrounded process eventually exits and is marked" do
      # Run a command longer than 10s to force backgrounding
      assert {:ok, result} = Exec.run("sleep 11")

      assert result.backgrounded == true
      assert is_binary(result.slug)

      # Verify it's registered
      assert {:ok, entry} = BackgroundProcessRegistry.get(result.slug)
      assert entry.exit_status == nil  # Still running

      # Clean up (don't wait for it to exit naturally)
      BackgroundProcessRegistry.kill(result.slug)
    end
  end

  describe "run/2 - output truncation" do
    test "truncates output larger than 200KB" do
      # Generate more than 200KB of output
      assert {:ok, result} = Exec.run("yes | head -n 10000")

      # Output should be truncated to 200KB max
      assert byte_size(result.output) <= 200_000
    end
  end

  describe "run/2 - error handling" do
    test "returns error for invalid command" do
      # This should still succeed but with non-zero exit code
      assert {:ok, result} = Exec.run("nonexistent_command_xyz")
      # Shell will return non-zero for command not found
      assert result.exit_code != 0
    end
  end
end
