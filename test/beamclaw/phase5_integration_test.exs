defmodule BeamClaw.Phase5IntegrationTest do
  use ExUnit.Case, async: false

  alias BeamClaw.Agent
  alias BeamClaw.Skill
  alias BeamClaw.Session
  alias BeamClaw.Session.SubAgent
  alias BeamClaw.Tool.Approval
  alias BeamClaw.Tool.Registry

  @moduletag :integration

  setup_all do
    # Initialize approval and registry systems
    Approval.init()
    Registry.init()
    :ok
  end

  setup do
    # Create a temporary directory for test skills
    tmp_dir = System.tmp_dir!() |> Path.join("beamclaw_phase5_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp_dir)

    # Create test skill files
    create_test_skills(tmp_dir)

    # Create a unique parent session
    parent_key = "agent:test:phase5-#{System.unique_integer([:positive])}"

    {:ok, _pid} = DynamicSupervisor.start_child(
      BeamClaw.SessionSupervisor,
      {Session, session_key: parent_key}
    )

    on_exit(fn ->
      File.rm_rf(tmp_dir)
    end)

    %{skills_dir: tmp_dir, parent_key: parent_key}
  end

  describe "Phase 5 Integration: Skills" do
    test "loads skills from directory and creates agent", %{skills_dir: skills_dir} do
      # 1. Load skills from test directory
      {:ok, skills} = Skill.scan_directory(skills_dir)

      assert length(skills) == 3
      skill_names = Enum.map(skills, & &1.name) |> Enum.sort()
      assert skill_names == ["always-skill", "optional-skill", "user-skill"]

      # Verify skill properties
      always_skill = Enum.find(skills, &(&1.name == "always-skill"))
      assert always_skill.always == true
      assert always_skill.user_invocable == false
      assert always_skill.description == "An always-on skill"

      optional_skill = Enum.find(skills, &(&1.name == "optional-skill"))
      assert optional_skill.always == false
      assert optional_skill.user_invocable == true

      user_skill = Enum.find(skills, &(&1.name == "user-skill"))
      assert user_skill.user_invocable == true
    end

    test "creates agent with loaded skills", %{skills_dir: skills_dir} do
      # 2. Create agent and load skills
      agent = Agent.new("integration-test", %{
        name: "Integration Test Agent",
        provider: "anthropic",
        model: "claude-sonnet-4-5-20250929"
      })

      assert agent.id == "integration-test"
      assert agent.name == "Integration Test Agent"
      assert agent.skills == []

      # Load skills into agent
      {:ok, agent_with_skills} = Agent.load_skills(agent, skills_dir)

      assert length(agent_with_skills.skills) == 3

      # Verify system prompt includes always-on skills
      system_prompt = Agent.system_prompt(agent_with_skills)

      assert String.contains?(system_prompt, "You are a helpful AI assistant.")
      assert String.contains?(system_prompt, "## Skills")
      assert String.contains?(system_prompt, "This skill is always active.")
      # Optional skills should NOT be in system prompt
      refute String.contains?(system_prompt, "This skill is optional.")
    end
  end

  describe "Phase 5 Integration: Sub-Agent Spawning" do
    test "spawns sub-agent from parent session", %{parent_key: parent_key} do
      # 3. Spawn a sub-agent from parent session
      {:ok, run} = SubAgent.spawn(parent_key, task: "Integration test task", label: "Test Sub-Agent")

      assert run.status == :running
      assert run.task == "Integration test task"
      assert run.label == "Test Sub-Agent"
      assert run.parent_session_key == parent_key
      assert run.cleanup == :delete
      assert is_binary(run.run_id)
      assert is_pid(run.child_pid)
      assert Process.alive?(run.child_pid)

      # Verify child session exists and has correct parent
      child_state = Session.get_state(run.child_session_key)
      assert child_state.parent_session != nil
      assert is_pid(child_state.parent_session)

      # Verify parent tracks the sub-agent
      runs = SubAgent.list_runs(parent_key)
      assert length(runs) == 1
      assert hd(runs).run_id == run.run_id

      # Verify sub-agent cannot spawn another sub-agent (depth limit)
      assert {:error, :sub_agents_cannot_spawn} =
        SubAgent.spawn(run.child_session_key, task: "Should fail")
    end

    test "parent monitors sub-agent lifecycle", %{parent_key: parent_key} do
      {:ok, run} = SubAgent.spawn(parent_key, task: "Monitor test")
      child_pid = run.child_pid

      # Monitor child ourselves
      ref = Process.monitor(child_pid)

      # Terminate child
      DynamicSupervisor.terminate_child(BeamClaw.SessionSupervisor, child_pid)

      # Wait for child to exit
      receive do
        {:DOWN, ^ref, :process, ^child_pid, _} -> :ok
      after
        1000 -> flunk("Child did not exit")
      end

      # Give parent time to process :DOWN
      Process.sleep(50)

      # Verify parent updated run status
      runs = SubAgent.list_runs(parent_key)
      assert length(runs) == 1
      [updated_run] = runs
      assert updated_run.status == :completed
      assert updated_run.ended_at != nil
    end
  end

  describe "Phase 5 Integration: Tool Approval Flow" do
    test "approval flow: request → approve → execute", %{parent_key: parent_key} do
      # 4. Tool approval flow
      session_key = parent_key
      tool_name = "dangerous_tool"
      args = %{"action" => "delete_all"}

      # Check approval with ask_mode: :always
      result = Approval.check(tool_name, args, ask_mode: :always, session_key: session_key)
      assert {:needs_approval, approval_id} = result

      # Spawn a task to request approval (async because it blocks)
      requester = Task.async(fn ->
        Approval.request_approval(approval_id, tool_name, args, session_key, 5000)
      end)

      # Give it a moment to broadcast
      Process.sleep(50)

      # Verify approval is pending
      pending = Approval.list_pending()
      assert length(pending) > 0
      approval = Enum.find(pending, &(&1.id == approval_id))
      assert approval != nil
      assert approval.tool == tool_name
      assert approval.args == args
      assert approval.session_key == session_key

      # Approve the request
      assert :ok = Approval.respond(approval_id, :approved)

      # Wait for requester to get response
      result = Task.await(requester)
      assert result == :approved

      # Verify approval is no longer pending
      pending_after = Approval.list_pending()
      assert Enum.find(pending_after, &(&1.id == approval_id)) == nil
    end

    test "approval with ask_mode: :off always approves", %{parent_key: parent_key} do
      session_key = parent_key
      result = Approval.check("any_tool", %{}, ask_mode: :off, session_key: session_key)
      assert result == :approved
    end

    test "approval with ask_mode: :on_miss uses allowlist", %{parent_key: parent_key} do
      session_key = parent_key
      allowlist = ["safe_tool", "exec", "web_*"]

      # Tool in allowlist - should be approved
      result1 = Approval.check("exec", %{}, ask_mode: :on_miss, allowlist: allowlist, session_key: session_key)
      assert result1 == :approved

      # Tool matching wildcard - should be approved
      result2 = Approval.check("web_fetch", %{}, ask_mode: :on_miss, allowlist: allowlist, session_key: session_key)
      assert result2 == :approved

      # Tool not in allowlist - should need approval
      result3 = Approval.check("dangerous_tool", %{}, ask_mode: :on_miss, allowlist: allowlist, session_key: session_key)
      assert {:needs_approval, _approval_id} = result3
    end

    test "approval request can be denied", %{parent_key: parent_key} do
      session_key = parent_key
      tool_name = "risky_operation"
      args = %{"risk_level" => "high"}

      {:needs_approval, approval_id} = Approval.check(tool_name, args, ask_mode: :always, session_key: session_key)

      # Request approval async
      requester = Task.async(fn ->
        Approval.request_approval(approval_id, tool_name, args, session_key, 5000)
      end)

      Process.sleep(50)

      # Deny the request
      assert :ok = Approval.respond(approval_id, :denied)

      # Verify requester got denial
      result = Task.await(requester)
      assert result == :denied
    end

    test "approval request times out without response", %{parent_key: parent_key} do
      session_key = parent_key
      {:needs_approval, approval_id} = Approval.check("timeout_tool", %{}, ask_mode: :always, session_key: session_key)

      # Request with very short timeout
      result = Approval.request_approval(approval_id, "timeout_tool", %{}, session_key, 100)
      assert result == {:error, :timeout}
    end
  end

  describe "Phase 5 Integration: Tool Registry with Approval" do
    test "register tools and integrate with approval", %{parent_key: parent_key} do
      # 5. Tool registry with approval integration
      session_key = parent_key

      # Register tools with different ask modes
      Registry.register(session_key, "exec", BeamClaw.Tool.Exec, ask_mode: :off)
      Registry.register(session_key, "web_fetch", BeamClaw.Tool.WebFetch, ask_mode: :on_miss, allowlist: ["web_fetch"])
      Registry.register(session_key, "custom_tool", DummyTool, ask_mode: :always, description: "A custom tool")

      # List all tools for session
      tools = Registry.list_tools(session_key)
      assert length(tools) == 3

      tool_names = Enum.map(tools, & &1.name) |> Enum.sort()
      assert tool_names == ["custom_tool", "exec", "web_fetch"]

      # Get specific tool
      {:ok, exec_tool} = Registry.get_tool(session_key, "exec")
      assert exec_tool.name == "exec"
      assert exec_tool.module == BeamClaw.Tool.Exec
      assert exec_tool.opts[:ask_mode] == :off

      {:ok, custom_tool} = Registry.get_tool(session_key, "custom_tool")
      assert custom_tool.opts[:ask_mode] == :always
      assert custom_tool.opts[:description] == "A custom tool"

      # Test approval integration with registered tools
      # Tool with ask_mode: :off should be auto-approved
      {:ok, exec_opts} = Registry.get_tool(session_key, "exec")
      exec_check = Approval.check("exec", %{}, exec_opts.opts)
      assert exec_check == :approved

      # Tool with ask_mode: :always should need approval
      {:ok, custom_opts} = Registry.get_tool(session_key, "custom_tool")
      custom_check = Approval.check("custom_tool", %{}, custom_opts.opts)
      assert {:needs_approval, _} = custom_check

      # Unregister a tool
      Registry.unregister(session_key, "custom_tool")
      assert {:error, :not_found} = Registry.get_tool(session_key, "custom_tool")

      # Verify only 2 tools remain
      remaining_tools = Registry.list_tools(session_key)
      assert length(remaining_tools) == 2
    end

    test "register default tools", %{parent_key: parent_key} do
      session_key = parent_key

      # Register defaults
      Registry.register_defaults(session_key)

      # Verify defaults are registered
      tools = Registry.list_tools(session_key)
      tool_names = Enum.map(tools, & &1.name) |> Enum.sort()
      assert "exec" in tool_names
      assert "web_fetch" in tool_names
    end
  end

  describe "Phase 5 Integration: Full Workflow" do
    test "end-to-end: agent with skills, sub-agent, and tool approval", %{skills_dir: skills_dir, parent_key: parent_key} do
      # Create agent with skills
      agent = Agent.new("e2e-test", %{name: "End-to-End Test Agent"})
      {:ok, agent} = Agent.load_skills(agent, skills_dir)

      # Verify agent has skills
      assert length(agent.skills) == 3

      # Spawn sub-agent
      {:ok, run} = SubAgent.spawn(parent_key, task: "E2E sub-task", cleanup: :keep)
      assert run.status == :running
      assert run.cleanup == :keep

      # Register tools for parent session
      Registry.register(parent_key, "safe_tool", DummyTool, ask_mode: :off)
      Registry.register(parent_key, "unsafe_tool", DummyTool, ask_mode: :always)

      # Safe tool should auto-approve
      {:ok, safe_tool} = Registry.get_tool(parent_key, "safe_tool")
      safe_check = Approval.check("safe_tool", %{}, safe_tool.opts)
      assert safe_check == :approved

      # Unsafe tool needs approval
      {:ok, unsafe_tool} = Registry.get_tool(parent_key, "unsafe_tool")
      unsafe_check = Approval.check("unsafe_tool", %{}, unsafe_tool.opts)
      assert {:needs_approval, approval_id} = unsafe_check

      # Approve it
      requester = Task.async(fn ->
        Approval.request_approval(approval_id, "unsafe_tool", %{}, parent_key, 5000)
      end)

      Process.sleep(50)
      Approval.respond(approval_id, :approved)
      assert :approved = Task.await(requester)

      # Clean up sub-agent
      SubAgent.cleanup_run(parent_key, run.run_id)
      runs = SubAgent.list_runs(parent_key)
      assert runs == []
    end
  end

  # Helper Functions

  defp create_test_skills(tmp_dir) do
    # Create always-on skill
    always_skill = Path.join(tmp_dir, "always-skill.md")
    File.write!(always_skill, """
    ---
    name: always-skill
    description: An always-on skill
    user-invocable: false
    always: true
    ---
    This skill is always active.
    It provides context to the agent.
    """)

    # Create optional skill
    optional_skill = Path.join(tmp_dir, "optional-skill.md")
    File.write!(optional_skill, """
    ---
    name: optional-skill
    description: An optional skill
    user-invocable: true
    always: false
    ---
    This skill is optional.
    It can be invoked when needed.
    """)

    # Create user-invocable skill
    user_skill = Path.join(tmp_dir, "user-skill.md")
    File.write!(user_skill, """
    ---
    name: user-skill
    user-invocable: true
    ---
    A simple user-invocable skill.
    """)
  end

  # Dummy tool module for testing
  defmodule DummyTool do
    def execute(_args), do: {:ok, "dummy result"}
  end
end
