defmodule BeamClaw.Skill do
  @moduledoc """
  Manages skill definitions loaded from SKILL.md files.

  Skills are markdown files with optional YAML frontmatter containing metadata.
  The frontmatter is delimited by `---` markers at the start of the file.

  ## Frontmatter Fields
  - `name` (string, required): Skill name (defaults to filename without .md)
  - `description` (string, optional): Brief description of the skill
  - `user-invocable` (boolean, default true): Whether users can invoke this skill
  - `always` (boolean, default false): Whether to include in system prompt always
  """

  defstruct [:name, :description, :content, :file_path, user_invocable: true, always: false]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          content: String.t(),
          file_path: String.t(),
          user_invocable: boolean(),
          always: boolean()
        }

  @doc """
  Scans a directory for all .md files and parses them as skills.

  Returns `{:ok, skills}` where skills is a list of `%Skill{}` structs,
  or `{:error, reason}` if the directory cannot be read.

  ## Examples

      iex> BeamClaw.Skill.scan_directory("/path/to/skills")
      {:ok, [%BeamClaw.Skill{name: "example", ...}]}
  """
  @spec scan_directory(Path.t()) :: {:ok, [t()]} | {:error, term()}
  def scan_directory(path) do
    case File.ls(path) do
      {:ok, files} ->
        skills =
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(&Path.join(path, &1))
          |> Enum.map(&parse_file/1)
          |> Enum.filter(fn
            {:ok, _} -> true
            {:error, _} -> false
          end)
          |> Enum.map(fn {:ok, skill} -> skill end)

        {:ok, skills}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses a single SKILL.md file into a Skill struct.

  Returns `{:ok, skill}` or `{:error, reason}`.

  ## Examples

      iex> BeamClaw.Skill.parse_file("/path/to/skill.md")
      {:ok, %BeamClaw.Skill{name: "skill", ...}}
  """
  @spec parse_file(Path.t()) :: {:ok, t()} | {:error, term()}
  def parse_file(path) do
    case File.read(path) do
      {:ok, text} ->
        filename = Path.basename(path, ".md")

        case parse_frontmatter(text) do
          {:ok, frontmatter, content} ->
            skill = %__MODULE__{
              name: Map.get(frontmatter, "name", filename),
              description: Map.get(frontmatter, "description"),
              content: content,
              file_path: path,
              user_invocable: Map.get(frontmatter, "user-invocable", true),
              always: Map.get(frontmatter, "always", false)
            }

            {:ok, skill}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses YAML frontmatter from markdown text.

  Frontmatter is delimited by `---` markers at the start of the file.
  Returns `{:ok, frontmatter_map, body}` where frontmatter_map is a map
  of parsed YAML values and body is the remaining content.

  If no frontmatter is found, returns `{:ok, %{}, text}`.

  ## Examples

      iex> text = \"\"\"
      ...> ---
      ...> name: example
      ...> ---
      ...> Content here
      ...> \"\"\"
      iex> BeamClaw.Skill.parse_frontmatter(text)
      {:ok, %{"name" => "example"}, "Content here\\n"}
  """
  @spec parse_frontmatter(String.t()) :: {:ok, map(), String.t()} | {:error, term()}
  def parse_frontmatter(text) do
    text = String.trim_leading(text)

    case String.split(text, "\n", parts: 2) do
      ["---", rest] ->
        # Has frontmatter
        case String.split(rest, "\n---\n", parts: 2) do
          [yaml_text, body] ->
            case YamlElixir.read_from_string(yaml_text) do
              {:ok, frontmatter} when is_map(frontmatter) ->
                {:ok, frontmatter, String.trim_leading(body)}

              {:ok, _} ->
                {:error, :invalid_frontmatter}

              {:error, reason} ->
                {:error, reason}
            end

          [_yaml_text] ->
            {:error, :unclosed_frontmatter}
        end

      _ ->
        # No frontmatter
        {:ok, %{}, text}
    end
  end
end
