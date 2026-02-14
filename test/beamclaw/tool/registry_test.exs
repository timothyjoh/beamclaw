defmodule BeamClaw.Tool.RegistryTest do
  use ExUnit.Case, async: false

  alias BeamClaw.Tool.Registry

  setup do
    # Initialize ETS table
    Registry.init()

    # Generate unique session key for each test
    session_key = "test:session:#{:erlang.unique_integer([:positive])}"

    {:ok, session_key: session_key}
  end

  describe "register/4 and get_tool/2" do
    test "registers and retrieves a tool", %{session_key: session_key} do
      :ok = Registry.register(session_key, "exec", BeamClaw.Tool.Exec, ask_mode: :always)

      assert {:ok, tool} = Registry.get_tool(session_key, "exec")
      assert tool.name == "exec"
      assert tool.module == BeamClaw.Tool.Exec
      assert tool.opts == [ask_mode: :always]
    end

    test "registers a tool with description", %{session_key: session_key} do
      :ok = Registry.register(
        session_key,
        "web_fetch",
        BeamClaw.Tool.WebFetch,
        ask_mode: :on_miss,
        description: "Fetch web content"
      )

      assert {:ok, tool} = Registry.get_tool(session_key, "web_fetch")
      assert tool.name == "web_fetch"
      assert tool.module == BeamClaw.Tool.WebFetch
      assert tool.opts[:ask_mode] == :on_miss
      assert tool.opts[:description] == "Fetch web content"
    end

    test "registers a tool with default options", %{session_key: session_key} do
      :ok = Registry.register(session_key, "custom_tool", MyCustomTool)

      assert {:ok, tool} = Registry.get_tool(session_key, "custom_tool")
      assert tool.name == "custom_tool"
      assert tool.module == MyCustomTool
      assert tool.opts == []
    end

    test "get_tool returns error for unregistered tool", %{session_key: session_key} do
      result = Registry.get_tool(session_key, "nonexistent")
      assert result == {:error, :not_found}
    end

    test "tools are session-scoped" do
      session1 = "test:session:1"
      session2 = "test:session:2"

      Registry.register(session1, "exec", BeamClaw.Tool.Exec)
      Registry.register(session2, "exec", BeamClaw.Tool.Exec)

      # Both sessions should have their own exec tool
      assert {:ok, _} = Registry.get_tool(session1, "exec")
      assert {:ok, _} = Registry.get_tool(session2, "exec")

      # Unregister from session1 shouldn't affect session2
      Registry.unregister(session1, "exec")
      assert {:error, :not_found} = Registry.get_tool(session1, "exec")
      assert {:ok, _} = Registry.get_tool(session2, "exec")
    end
  end

  describe "list_tools/1" do
    test "lists all tools for a session", %{session_key: session_key} do
      Registry.register(session_key, "exec", BeamClaw.Tool.Exec, ask_mode: :always)
      Registry.register(session_key, "web_fetch", BeamClaw.Tool.WebFetch, ask_mode: :on_miss)

      tools = Registry.list_tools(session_key)
      assert length(tools) == 2

      exec_tool = Enum.find(tools, fn t -> t.name == "exec" end)
      assert exec_tool.module == BeamClaw.Tool.Exec
      assert exec_tool.opts == [ask_mode: :always]

      web_fetch_tool = Enum.find(tools, fn t -> t.name == "web_fetch" end)
      assert web_fetch_tool.module == BeamClaw.Tool.WebFetch
      assert web_fetch_tool.opts == [ask_mode: :on_miss]
    end

    test "returns empty list for session with no tools", %{session_key: session_key} do
      tools = Registry.list_tools(session_key)
      assert tools == []
    end

    test "only lists tools for the specified session" do
      session1 = "test:session:list1"
      session2 = "test:session:list2"

      Registry.register(session1, "exec", BeamClaw.Tool.Exec)
      Registry.register(session2, "web_fetch", BeamClaw.Tool.WebFetch)

      tools1 = Registry.list_tools(session1)
      assert length(tools1) == 1
      assert Enum.at(tools1, 0).name == "exec"

      tools2 = Registry.list_tools(session2)
      assert length(tools2) == 1
      assert Enum.at(tools2, 0).name == "web_fetch"
    end
  end

  describe "unregister/2" do
    test "removes a registered tool", %{session_key: session_key} do
      Registry.register(session_key, "exec", BeamClaw.Tool.Exec)
      assert {:ok, _} = Registry.get_tool(session_key, "exec")

      :ok = Registry.unregister(session_key, "exec")
      assert {:error, :not_found} = Registry.get_tool(session_key, "exec")
    end

    test "unregister is idempotent", %{session_key: session_key} do
      Registry.register(session_key, "exec", BeamClaw.Tool.Exec)

      :ok = Registry.unregister(session_key, "exec")
      :ok = Registry.unregister(session_key, "exec")

      assert {:error, :not_found} = Registry.get_tool(session_key, "exec")
    end

    test "unregister only affects the specified tool", %{session_key: session_key} do
      Registry.register(session_key, "exec", BeamClaw.Tool.Exec)
      Registry.register(session_key, "web_fetch", BeamClaw.Tool.WebFetch)

      Registry.unregister(session_key, "exec")

      assert {:error, :not_found} = Registry.get_tool(session_key, "exec")
      assert {:ok, _} = Registry.get_tool(session_key, "web_fetch")
    end
  end

  describe "register_defaults/1" do
    test "registers exec and web_fetch tools", %{session_key: session_key} do
      :ok = Registry.register_defaults(session_key)

      assert {:ok, exec_tool} = Registry.get_tool(session_key, "exec")
      assert exec_tool.module == BeamClaw.Tool.Exec

      assert {:ok, web_fetch_tool} = Registry.get_tool(session_key, "web_fetch")
      assert web_fetch_tool.module == BeamClaw.Tool.WebFetch
    end

    test "default tools appear in list_tools", %{session_key: session_key} do
      Registry.register_defaults(session_key)

      tools = Registry.list_tools(session_key)
      assert length(tools) == 2

      tool_names = Enum.map(tools, & &1.name)
      assert "exec" in tool_names
      assert "web_fetch" in tool_names
    end
  end
end
