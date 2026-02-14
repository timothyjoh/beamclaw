defmodule BeamClaw.Provider.SSETest do
  use ExUnit.Case, async: true

  alias BeamClaw.Provider.SSE

  describe "parse/2" do
    test "parses a single complete event" do
      data = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n"
      {events, buffer} = SSE.parse(data)
      assert [%{event: "message_start", data: "{\"type\":\"message_start\"}"}] = events
      assert buffer == ""
    end

    test "parses multiple complete events" do
      data = "event: content_block_start\ndata: {\"index\":0}\n\nevent: content_block_delta\ndata: {\"text\":\"Hi\"}\n\n"
      {events, buffer} = SSE.parse(data)
      assert length(events) == 2
      assert Enum.at(events, 0).event == "content_block_start"
      assert Enum.at(events, 1).event == "content_block_delta"
      assert buffer == ""
    end

    test "buffers incomplete events" do
      data = "event: message_start\ndata: {\"type\":"
      {events, buffer} = SSE.parse(data)
      assert events == []
      assert buffer == data
    end

    test "continues from buffer" do
      # First chunk — incomplete
      {events1, buffer} = SSE.parse("event: ping\ndata: {\"a\":")
      assert events1 == []

      # Second chunk — completes the event
      {events2, buffer2} = SSE.parse("1}\n\n", buffer)
      assert [%{event: "ping", data: "{\"a\":1}"}] = events2
      assert buffer2 == ""
    end

    test "handles empty input" do
      {events, buffer} = SSE.parse("")
      assert events == []
      assert buffer == ""
    end

    test "handles event with extra whitespace" do
      data = "event: message_stop\ndata: {}\n\n"
      {events, _buffer} = SSE.parse(data)
      assert [%{event: "message_stop", data: "{}"}] = events
    end

    test "skips malformed events missing data line" do
      data = "event: test\n\n"
      {events, _buffer} = SSE.parse(data)
      assert events == []
    end
  end
end
