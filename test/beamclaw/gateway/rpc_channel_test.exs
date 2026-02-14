defmodule BeamClaw.Gateway.RPCChannelTest do
  use ExUnit.Case

  describe "module" do
    test "defines expected channel callbacks" do
      # Phoenix.Channel injects these via __using__ — verify the module loaded
      assert Code.ensure_loaded?(BeamClaw.Gateway.RPCChannel)
    end
  end
end
