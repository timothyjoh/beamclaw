defmodule BeamClaw.AgentTest do
  use ExUnit.Case, async: true

  alias BeamClaw.Agent
  alias BeamClaw.Skill

  describe "new/2" do
    test "creates agent with defaults" do
      agent = Agent.new("test-agent")

      assert agent.id == "test-agent"
      assert agent.name == nil
      assert agent.provider == "anthropic"
      assert agent.model == "claude-sonnet-4-5-20250929"
      assert agent.system_prompt == "You are a helpful AI assistant."
      assert agent.skills == []
      assert agent.config == %{}
    end

    test "creates agent with custom config" do
      config = %{
        name: "My Test Agent",
        provider: "custom-provider",
        model: "custom-model",
        system_prompt: "Custom system prompt.",
        extra_field: "extra"
      }

      agent = Agent.new("custom-agent", config)

      assert agent.id == "custom-agent"
      assert agent.name == "My Test Agent"
      assert agent.provider == "custom-provider"
      assert agent.model == "custom-model"
      assert agent.system_prompt == "Custom system prompt."
      assert agent.skills == []
      assert agent.config == config
    end

    test "config fields override defaults" do
      agent = Agent.new("test", %{provider: "openai", model: "gpt-4"})

      assert agent.provider == "openai"
      assert agent.model == "gpt-4"
      # Other fields remain default
      assert agent.system_prompt == "You are a helpful AI assistant."
    end
  end

  describe "load_skills/2" do
    setup do
      tmp_dir = System.tmp_dir!() |> Path.join("beamclaw_agent_test_#{:rand.uniform(999_999)}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        File.rm_rf(tmp_dir)
      end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "loads skills from directory", %{tmp_dir: tmp_dir} do
      # Create skill files
      File.write!(Path.join(tmp_dir, "skill1.md"), """
      ---
      name: skill-one
      description: First skill
      ---
      Content one.
      """)

      File.write!(Path.join(tmp_dir, "skill2.md"), """
      ---
      name: skill-two
      always: true
      ---
      Content two.
      """)

      agent = Agent.new("test-agent")
      assert {:ok, updated_agent} = Agent.load_skills(agent, tmp_dir)

      assert length(updated_agent.skills) == 2
      names = Enum.map(updated_agent.skills, & &1.name) |> Enum.sort()
      assert names == ["skill-one", "skill-two"]
    end

    test "returns empty skills list for empty directory", %{tmp_dir: tmp_dir} do
      agent = Agent.new("test-agent")
      assert {:ok, updated_agent} = Agent.load_skills(agent, tmp_dir)

      assert updated_agent.skills == []
    end

    test "returns error for unreadable directory" do
      agent = Agent.new("test-agent")
      # Create a file (not directory) to trigger an error
      file_path = Path.join(System.tmp_dir!(), "not_a_directory_#{:rand.uniform(999_999)}")
      File.write!(file_path, "content")

      on_exit(fn -> File.rm(file_path) end)

      assert {:error, _reason} = Agent.load_skills(agent, file_path)
    end
  end

  describe "system_prompt/1" do
    test "returns base system prompt with no skills" do
      agent = %Agent{
        id: "test",
        system_prompt: "You are a helpful assistant.",
        skills: []
      }

      assert Agent.system_prompt(agent) == "You are a helpful assistant."
    end

    test "returns base system prompt with no always-on skills" do
      agent = %Agent{
        id: "test",
        system_prompt: "You are helpful.",
        skills: [
          %Skill{name: "optional1", content: "Optional skill.", always: false},
          %Skill{name: "optional2", content: "Another optional.", always: false}
        ]
      }

      assert Agent.system_prompt(agent) == "You are helpful."
    end

    test "includes always-on skills in system prompt" do
      agent = %Agent{
        id: "test",
        system_prompt: "You are helpful.",
        skills: [
          %Skill{name: "always1", content: "Always skill one.", always: true},
          %Skill{name: "optional", content: "Optional skill.", always: false},
          %Skill{name: "always2", content: "Always skill two.", always: true}
        ]
      }

      prompt = Agent.system_prompt(agent)

      assert prompt == "You are helpful.\n\n## Skills\n\nAlways skill one.\n\nAlways skill two."
      refute String.contains?(prompt, "Optional skill")
    end

    test "formats multiple always-on skills correctly" do
      agent = %Agent{
        id: "test",
        system_prompt: "Base prompt.",
        skills: [
          %Skill{name: "skill1", content: "First content.", always: true},
          %Skill{name: "skill2", content: "Second content.", always: true},
          %Skill{name: "skill3", content: "Third content.", always: true}
        ]
      }

      prompt = Agent.system_prompt(agent)

      expected = """
      Base prompt.

      ## Skills

      First content.

      Second content.

      Third content.\
      """

      assert prompt == expected
    end
  end
end
