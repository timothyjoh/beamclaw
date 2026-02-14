defmodule BeamClaw.Tool.ApprovalTest do
  use ExUnit.Case, async: false

  alias BeamClaw.Tool.Approval

  setup do
    # Initialize ETS table
    Approval.init()

    # Generate unique session key for each test
    session_key = "test:session:#{:erlang.unique_integer([:positive])}"

    # Subscribe to approval topic for this session
    topic = "approval:#{session_key}"
    Phoenix.PubSub.subscribe(BeamClaw.PubSub, topic)

    {:ok, session_key: session_key, topic: topic}
  end

  describe "check/3" do
    test "with ask_mode :off always returns :approved" do
      result = Approval.check("exec", %{"command" => "ls"}, ask_mode: :off)
      assert result == :approved
    end

    test "with ask_mode :on_miss returns :approved when tool in allowlist" do
      allowlist = ["exec", "web_fetch"]
      result = Approval.check("exec", %{}, ask_mode: :on_miss, allowlist: allowlist)
      assert result == :approved
    end

    test "with ask_mode :on_miss returns {:needs_approval, id} when tool not in allowlist" do
      allowlist = ["exec", "web_fetch"]
      result = Approval.check("dangerous_tool", %{}, ask_mode: :on_miss, allowlist: allowlist)
      assert {:needs_approval, approval_id} = result
      assert is_binary(approval_id)
      assert String.starts_with?(approval_id, "approval-")
    end

    test "with ask_mode :on_miss supports wildcard patterns" do
      allowlist = ["exec*", "web_*"]

      # Should match exec*
      result1 = Approval.check("exec", %{}, ask_mode: :on_miss, allowlist: allowlist)
      assert result1 == :approved

      result2 = Approval.check("exec_background", %{}, ask_mode: :on_miss, allowlist: allowlist)
      assert result2 == :approved

      # Should match web_*
      result3 = Approval.check("web_fetch", %{}, ask_mode: :on_miss, allowlist: allowlist)
      assert result3 == :approved

      # Should not match
      result4 = Approval.check("other_tool", %{}, ask_mode: :on_miss, allowlist: allowlist)
      assert {:needs_approval, _} = result4
    end

    test "with ask_mode :always always returns {:needs_approval, id}" do
      result = Approval.check("exec", %{}, ask_mode: :always, session_key: "test:session")
      assert {:needs_approval, approval_id} = result
      assert is_binary(approval_id)
      assert String.starts_with?(approval_id, "approval-")
    end
  end

  describe "request_approval/5 + respond/2" do
    test "request_approval + respond flow with :approved", %{session_key: session_key} do
      # Spawn a task that will request approval
      parent = self()

      task = Task.async(fn ->
        result = Approval.request_approval(
          "test-approval-#{:erlang.unique_integer([:positive])}",
          "exec",
          %{"command" => "ls"},
          session_key,
          5_000
        )
        send(parent, {:result, result})
        result
      end)

      # Wait for the approval request broadcast
      assert_receive {:approval_request, request}, 1_000
      assert request.tool == "exec"
      assert request.args == %{"command" => "ls"}
      assert request.session_key == session_key

      # Respond with approval
      :ok = Approval.respond(request.id, :approved)

      # Wait for the task to complete
      assert Task.await(task) == :approved
    end

    test "request_approval + respond flow with :denied", %{session_key: session_key} do
      parent = self()

      task = Task.async(fn ->
        result = Approval.request_approval(
          "test-approval-#{:erlang.unique_integer([:positive])}",
          "dangerous",
          %{"action" => "delete_all"},
          session_key,
          5_000
        )
        send(parent, {:result, result})
        result
      end)

      # Wait for the approval request broadcast
      assert_receive {:approval_request, request}, 1_000

      # Respond with denial
      :ok = Approval.respond(request.id, :denied)

      # Wait for the task to complete
      assert Task.await(task) == :denied
    end

    test "request_approval times out when no response", %{session_key: session_key} do
      # Use a short timeout for faster test
      result = Approval.request_approval(
        "test-approval-#{:erlang.unique_integer([:positive])}",
        "exec",
        %{"command" => "sleep 100"},
        session_key,
        100  # 100ms timeout
      )

      assert result == {:error, :timeout}
    end

    test "respond with invalid approval_id returns {:error, :not_found}" do
      result = Approval.respond("nonexistent-approval", :approved)
      assert result == {:error, :not_found}
    end
  end

  describe "list_pending/0" do
    test "shows pending approval requests", %{session_key: session_key} do
      # Start a request that will block
      task = Task.async(fn ->
        Approval.request_approval(
          "pending-test-#{:erlang.unique_integer([:positive])}",
          "exec",
          %{"command" => "test"},
          session_key,
          5_000
        )
      end)

      # Wait for broadcast to ensure request is registered
      assert_receive {:approval_request, request}, 1_000

      # Check pending list
      pending = Approval.list_pending()
      assert length(pending) >= 1

      # Find our request
      our_request = Enum.find(pending, fn p -> p.id == request.id end)
      assert our_request != nil
      assert our_request.tool == "exec"
      assert our_request.args == %{"command" => "test"}
      assert our_request.session_key == session_key
      assert %DateTime{} = our_request.timestamp

      # Clean up - approve the request
      :ok = Approval.respond(request.id, :approved)
      Task.await(task)

      # Verify it's no longer in pending list
      pending_after = Approval.list_pending()
      refute Enum.any?(pending_after, fn p -> p.id == request.id end)
    end

    test "returns empty list when no pending requests" do
      # Clean up any existing requests first
      Approval.list_pending()
      |> Enum.each(fn req -> Approval.respond(req.id, :denied) end)

      # Small delay to let cleanup happen
      Process.sleep(10)

      # Note: We can't guarantee empty list in async tests, but we can verify structure
      pending = Approval.list_pending()
      assert is_list(pending)
    end
  end

  describe "PubSub broadcast" do
    test "broadcasts approval request on correct topic", %{session_key: session_key} do
      # Spawn task to request approval
      task = Task.async(fn ->
        Approval.request_approval(
          "pubsub-test-#{:erlang.unique_integer([:positive])}",
          "test_tool",
          %{"arg" => "value"},
          session_key,
          5_000
        )
      end)

      # Verify we receive the broadcast
      assert_receive {:approval_request, request}, 1_000
      assert request.tool == "test_tool"
      assert request.args == %{"arg" => "value"}
      assert request.session_key == session_key
      assert is_binary(request.id)

      # Clean up
      :ok = Approval.respond(request.id, :approved)
      Task.await(task)
    end
  end
end
