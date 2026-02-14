defmodule BeamClaw.Agent do
  @moduledoc """
  Represents an AI agent with its configuration, skills, and provider settings.

  An agent combines:
  - Identity (id, name)
  - Provider settings (provider, model)
  - System prompt
  - Skills (including always-on skills that augment the system prompt)
  - Additional configuration
  """

  alias BeamClaw.Skill

  defstruct [:id, :name, :provider, :model, :system_prompt, skills: [], config: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          provider: String.t(),
          model: String.t(),
          system_prompt: String.t(),
          skills: [Skill.t()],
          config: map()
        }

  @default_provider "anthropic"
  @default_model "claude-sonnet-4-5-20250929"
  @default_system_prompt "You are a helpful AI assistant."

  @doc """
  Creates a new agent with the given ID and optional configuration.

  ## Config Options
  - `:name` (string): Human-readable name for the agent
  - `:provider` (string): Provider to use (default: "anthropic")
  - `:model` (string): Model to use (default: "claude-sonnet-4-5-20250929")
  - `:system_prompt` (string): Base system prompt (default: "You are a helpful AI assistant.")

  ## Examples

      iex> BeamClaw.Agent.new("my-agent")
      %BeamClaw.Agent{id: "my-agent", provider: "anthropic", ...}

      iex> BeamClaw.Agent.new("my-agent", %{name: "My Agent", model: "claude-opus-4-6"})
      %BeamClaw.Agent{id: "my-agent", name: "My Agent", model: "claude-opus-4-6", ...}
  """
  @spec new(String.t(), map()) :: t()
  def new(id, config \\ %{}) do
    %__MODULE__{
      id: id,
      name: Map.get(config, :name),
      provider: Map.get(config, :provider, @default_provider),
      model: Map.get(config, :model, @default_model),
      system_prompt: Map.get(config, :system_prompt, @default_system_prompt),
      skills: [],
      config: config
    }
  end

  @doc """
  Loads skills from a directory and attaches them to the agent.

  Returns `{:ok, agent}` with updated skills list, or `{:error, reason}`.

  ## Examples

      iex> agent = BeamClaw.Agent.new("my-agent")
      iex> BeamClaw.Agent.load_skills(agent, "/path/to/skills")
      {:ok, %BeamClaw.Agent{skills: [%BeamClaw.Skill{}, ...]}}
  """
  @spec load_skills(t(), Path.t()) :: {:ok, t()} | {:error, term()}
  def load_skills(%__MODULE__{} = agent, skills_dir) do
    case Skill.scan_directory(skills_dir) do
      {:ok, skills} ->
        {:ok, %{agent | skills: skills}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the full system prompt for the agent.

  The system prompt includes:
  1. The base system_prompt
  2. Content from all skills marked with `always: true`

  Always-on skills are appended in a "## Skills" section.

  ## Examples

      iex> agent = %BeamClaw.Agent{system_prompt: "You are helpful."}
      iex> BeamClaw.Agent.system_prompt(agent)
      "You are helpful."

      iex> agent = %BeamClaw.Agent{
      ...>   system_prompt: "You are helpful.",
      ...>   skills: [
      ...>     %BeamClaw.Skill{name: "always-on", content: "Always do this.", always: true},
      ...>     %BeamClaw.Skill{name: "optional", content: "Optional skill.", always: false}
      ...>   ]
      ...> }
      iex> BeamClaw.Agent.system_prompt(agent)
      "You are helpful.\\n\\n## Skills\\n\\nAlways do this."
  """
  @spec system_prompt(t()) :: String.t()
  def system_prompt(%__MODULE__{} = agent) do
    always_skills =
      agent.skills
      |> Enum.filter(& &1.always)
      |> Enum.map(& &1.content)

    case always_skills do
      [] ->
        agent.system_prompt

      skills_content ->
        agent.system_prompt <> "\n\n## Skills\n\n" <> Enum.join(skills_content, "\n\n")
    end
  end
end
