defmodule BeamClaw.Session.StoreTest do
  use ExUnit.Case

  alias BeamClaw.Session.Store

  @test_key "agent:default:test-#{System.unique_integer([:positive])}"

  setup do
    # Clean up test file after each test
    path = Store.transcript_path(@test_key)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  describe "transcript_path/1" do
    test "converts colons to dashes" do
      path = Store.transcript_path("agent:default:main")
      assert String.ends_with?(path, "agent-default-main.jsonl")
    end

    test "includes sessions directory" do
      path = Store.transcript_path("agent:ops:test")
      assert path =~ "/sessions/"
    end
  end

  describe "append_message/2 and load_messages/1" do
    test "appends and loads a user message" do
      msg = %{role: "user", content: "Hello"}
      assert :ok = Store.append_message(@test_key, msg)

      messages = Store.load_messages(@test_key)
      assert length(messages) == 1
      assert hd(messages).role == "user"
      assert hd(messages).content == "Hello"
    end

    test "appends multiple messages" do
      Store.append_message(@test_key, %{role: "user", content: "Hi"})
      Store.append_message(@test_key, %{role: "assistant", content: "Hello!"})

      messages = Store.load_messages(@test_key)
      assert length(messages) == 2
      assert Enum.at(messages, 0).role == "user"
      assert Enum.at(messages, 1).role == "assistant"
    end

    test "creates session header on first write" do
      Store.append_message(@test_key, %{role: "user", content: "test"})

      path = Store.transcript_path(@test_key)
      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)

      # First line should be session header
      {:ok, header} = Jason.decode(hd(lines))
      assert header["type"] == "session"
      assert header["version"] == 1
      assert header["session_key"] == @test_key
    end

    test "load_messages returns empty list for missing file" do
      assert Store.load_messages("agent:default:nonexistent-#{System.unique_integer()}") == []
    end
  end
end
