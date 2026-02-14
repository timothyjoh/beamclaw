defmodule BeamClaw.ConfigTest do
  use ExUnit.Case

  describe "get/1" do
    test "returns default model" do
      assert BeamClaw.Config.get(:default_model) == "claude-sonnet-4-5-20250929"
    end

    test "returns default max tokens" do
      assert BeamClaw.Config.get(:default_max_tokens) == 8192
    end

    test "returns data dir" do
      data_dir = BeamClaw.Config.get(:data_dir)
      assert is_binary(data_dir)
      assert String.ends_with?(data_dir, "beamclaw/data")
    end

    test "returns nil for unknown key" do
      assert BeamClaw.Config.get(:nonexistent) == nil
    end
  end

  describe "get/2 with default" do
    test "returns default for missing key" do
      assert BeamClaw.Config.get(:missing_key, "fallback") == "fallback"
    end

    test "returns actual value when key exists" do
      assert BeamClaw.Config.get(:default_model, "fallback") == "claude-sonnet-4-5-20250929"
    end
  end
end
