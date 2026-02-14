defmodule BeamClaw.SkillTest do
  use ExUnit.Case, async: true

  alias BeamClaw.Skill

  describe "parse_frontmatter/1" do
    test "parses frontmatter with all fields" do
      text = """
      ---
      name: test-skill
      description: A test skill
      user-invocable: false
      always: true
      ---
      This is the content.
      """

      assert {:ok, frontmatter, content} = Skill.parse_frontmatter(text)
      assert frontmatter["name"] == "test-skill"
      assert frontmatter["description"] == "A test skill"
      assert frontmatter["user-invocable"] == false
      assert frontmatter["always"] == true
      assert content == "This is the content.\n"
    end

    test "parses frontmatter with missing optional fields" do
      text = """
      ---
      name: minimal-skill
      ---
      Content here.
      """

      assert {:ok, frontmatter, content} = Skill.parse_frontmatter(text)
      assert frontmatter["name"] == "minimal-skill"
      assert frontmatter["description"] == nil
      assert frontmatter["user-invocable"] == nil
      assert frontmatter["always"] == nil
      assert content == "Content here.\n"
    end

    test "parses file with no frontmatter" do
      text = "Just plain content without frontmatter."

      assert {:ok, frontmatter, content} = Skill.parse_frontmatter(text)
      assert frontmatter == %{}
      assert content == text
    end

    test "returns error for unclosed frontmatter" do
      text = """
      ---
      name: broken
      This should have a closing ---
      """

      assert {:error, :unclosed_frontmatter} = Skill.parse_frontmatter(text)
    end

    test "returns error for invalid YAML" do
      text = """
      ---
      name: [invalid: yaml: syntax
      ---
      Content
      """

      assert {:error, _reason} = Skill.parse_frontmatter(text)
    end
  end

  describe "parse_file/1" do
    setup do
      tmp_dir = System.tmp_dir!() |> Path.join("beamclaw_skill_test_#{:rand.uniform(999_999)}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        File.rm_rf(tmp_dir)
      end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "parses file with complete frontmatter", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "complete.md")

      content = """
      ---
      name: complete-skill
      description: A complete skill
      user-invocable: true
      always: false
      ---
      This is the skill content.
      It can have multiple lines.
      """

      File.write!(file_path, content)

      assert {:ok, skill} = Skill.parse_file(file_path)
      assert skill.name == "complete-skill"
      assert skill.description == "A complete skill"
      assert skill.user_invocable == true
      assert skill.always == false
      assert skill.content == "This is the skill content.\nIt can have multiple lines.\n"
      assert skill.file_path == file_path
    end

    test "uses filename as name when frontmatter missing name", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "my-skill.md")

      content = """
      ---
      description: No name in frontmatter
      ---
      Content here.
      """

      File.write!(file_path, content)

      assert {:ok, skill} = Skill.parse_file(file_path)
      assert skill.name == "my-skill"
      assert skill.description == "No name in frontmatter"
    end

    test "uses filename and defaults when no frontmatter", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "simple.md")
      File.write!(file_path, "Just content, no frontmatter.")

      assert {:ok, skill} = Skill.parse_file(file_path)
      assert skill.name == "simple"
      assert skill.description == nil
      assert skill.user_invocable == true
      assert skill.always == false
      assert skill.content == "Just content, no frontmatter."
    end

    test "returns error for nonexistent file" do
      assert {:error, :enoent} = Skill.parse_file("/nonexistent/file.md")
    end
  end

  describe "scan_directory/1" do
    setup do
      tmp_dir = System.tmp_dir!() |> Path.join("beamclaw_skill_scan_#{:rand.uniform(999_999)}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        File.rm_rf(tmp_dir)
      end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "scans directory with multiple skill files", %{tmp_dir: tmp_dir} do
      # Create multiple skill files
      skill1 = Path.join(tmp_dir, "skill1.md")
      skill2 = Path.join(tmp_dir, "skill2.md")
      skill3 = Path.join(tmp_dir, "skill3.md")

      File.write!(skill1, """
      ---
      name: first-skill
      ---
      First skill content.
      """)

      File.write!(skill2, """
      ---
      name: second-skill
      always: true
      ---
      Second skill content.
      """)

      File.write!(skill3, "Third skill, no frontmatter.")

      assert {:ok, skills} = Skill.scan_directory(tmp_dir)
      assert length(skills) == 3

      names = Enum.map(skills, & &1.name) |> Enum.sort()
      assert names == ["first-skill", "second-skill", "skill3"]

      # Verify always flag
      always_skill = Enum.find(skills, &(&1.name == "second-skill"))
      assert always_skill.always == true
    end

    test "ignores non-markdown files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "skill.md"), "Valid skill.")
      File.write!(Path.join(tmp_dir, "readme.txt"), "Not a skill.")
      File.write!(Path.join(tmp_dir, "config.json"), "{}")

      assert {:ok, skills} = Skill.scan_directory(tmp_dir)
      assert length(skills) == 1
      assert hd(skills).name == "skill"
    end

    test "returns empty list for empty directory", %{tmp_dir: tmp_dir} do
      assert {:ok, skills} = Skill.scan_directory(tmp_dir)
      assert skills == []
    end

    test "returns empty list for nonexistent directory" do
      assert {:ok, skills} = Skill.scan_directory("/nonexistent/directory")
      assert skills == []
    end

    test "content excludes frontmatter", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "test.md")

      File.write!(file_path, """
      ---
      name: test
      ---
      Only this content should be included.
      Not the frontmatter.
      """)

      assert {:ok, [skill]} = Skill.scan_directory(tmp_dir)
      assert skill.content == "Only this content should be included.\nNot the frontmatter.\n"
      refute String.contains?(skill.content, "name: test")
      refute String.contains?(skill.content, "---")
    end
  end
end
