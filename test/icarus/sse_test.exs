defmodule Icarus.SSETest do
  use ExUnit.Case, async: true

  alias Icarus.SSE

  describe "new/0" do
    test "creates parser with empty buffer" do
      parser = SSE.new()
      assert parser.buffer == ""
    end
  end

  describe "feed/2 with complete events" do
    test "parses single event" do
      parser = SSE.new()
      chunk = "event: message_start\ndata: {\"type\": \"message_start\"}\n\n"

      {parser, events} = SSE.feed(parser, chunk)

      assert parser.buffer == ""
      assert length(events) == 1
      assert hd(events).event == "message_start"
      assert hd(events).data == %{"type" => "message_start"}
    end

    test "parses multiple events in single chunk" do
      parser = SSE.new()

      chunk = """
      event: message_start
      data: {"type": "message_start"}

      event: content_block_start
      data: {"type": "content_block_start", "index": 0}

      """

      {parser, events} = SSE.feed(parser, chunk)

      assert parser.buffer == ""
      assert length(events) == 2
      assert Enum.at(events, 0).event == "message_start"
      assert Enum.at(events, 1).event == "content_block_start"
      assert Enum.at(events, 1).data["index"] == 0
    end

    test "parses ping events" do
      parser = SSE.new()
      chunk = "event: ping\ndata: {}\n\n"

      {_parser, events} = SSE.feed(parser, chunk)

      assert length(events) == 1
      assert hd(events).event == "ping"
    end
  end

  describe "feed/2 with chunked data" do
    test "buffers partial JSON until complete" do
      parser = SSE.new()

      chunk1 = "event: message_start\ndata: {\"type\": \"mes"
      {parser, events} = SSE.feed(parser, chunk1)
      assert events == []
      assert parser.buffer == chunk1

      chunk2 = "sage_start\", \"message\": {}}\n\n"
      {parser, events} = SSE.feed(parser, chunk2)
      assert parser.buffer == ""
      assert length(events) == 1
      assert hd(events).event == "message_start"
      assert hd(events).data == %{"type" => "message_start", "message" => %{}}
    end

    test "buffers partial event name until complete" do
      parser = SSE.new()

      chunk1 = "event: message_st"
      {parser, events} = SSE.feed(parser, chunk1)
      assert events == []

      chunk2 = "art\ndata: {\"type\": \"message_start\"}\n\n"
      {_parser, events} = SSE.feed(parser, chunk2)
      assert length(events) == 1
      assert hd(events).event == "message_start"
    end

    test "reassembles event split across many small chunks" do
      parser = SSE.new()
      full_event = "event: content_block_delta\ndata: {\"type\": \"delta\", \"text\": \"Hello\"}\n\n"

      chunks = String.graphemes(full_event) |> Enum.chunk_every(5) |> Enum.map(&Enum.join/1)

      {final_parser, all_events} =
        Enum.reduce(chunks, {parser, []}, fn chunk, {p, events} ->
          {new_p, new_events} = SSE.feed(p, chunk)
          {new_p, events ++ new_events}
        end)

      assert final_parser.buffer == ""
      assert length(all_events) == 1
      assert hd(all_events).data["text"] == "Hello"
    end

    test "returns complete event and buffers next partial" do
      parser = SSE.new()

      chunk1 = "event: message_start\ndata: {\"type\": \"start\"}\n\nevent: delta\ndata: {\"tex"
      {parser, events} = SSE.feed(parser, chunk1)
      assert length(events) == 1
      assert hd(events).event == "message_start"
      assert parser.buffer == "event: delta\ndata: {\"tex"

      chunk2 = "t\": \"hi\"}\n\n"
      {parser, events} = SSE.feed(parser, chunk2)
      assert length(events) == 1
      assert hd(events).data["text"] == "hi"
      assert parser.buffer == ""
    end

    test "handles message_start split across three chunks" do
      parser = SSE.new()

      chunk1 = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_"
      chunk2 = "01JWR\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-"
      chunk3 = "sonnet-4-20250514\",\"stop_reason\":null}}\n\n"

      {parser, events1} = SSE.feed(parser, chunk1)
      assert events1 == []
      assert parser.buffer != ""

      {parser, events2} = SSE.feed(parser, chunk2)
      assert events2 == []

      {parser, events3} = SSE.feed(parser, chunk3)
      assert length(events3) == 1
      assert hd(events3).data["message"]["id"] == "msg_01JWR"
      assert parser.buffer == ""
    end
  end

  describe "feed/2 with Anthropic event types" do
    test "parses message_start with full message object" do
      parser = SSE.new()

      chunk = """
      event: message_start
      data: {"type":"message_start","message":{"id":"msg_123","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-20250514","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1}}}

      """

      {_parser, events} = SSE.feed(parser, chunk)

      assert length(events) == 1
      event = hd(events)
      assert event.event == "message_start"
      assert event.data["message"]["id"] == "msg_123"
      assert event.data["message"]["model"] == "claude-sonnet-4-20250514"
    end

    test "parses content_block_delta with text" do
      parser = SSE.new()

      chunk = """
      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

      """

      {_parser, events} = SSE.feed(parser, chunk)

      assert length(events) == 1
      event = hd(events)
      assert event.data["delta"]["type"] == "text_delta"
      assert event.data["delta"]["text"] == "Hello"
    end

    test "parses thinking_delta events" do
      parser = SSE.new()

      chunk = """
      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me analyze..."}}

      """

      {_parser, events} = SSE.feed(parser, chunk)

      assert length(events) == 1
      assert hd(events).data["delta"]["type"] == "thinking_delta"
      assert hd(events).data["delta"]["thinking"] == "Let me analyze..."
    end

    test "parses tool_use content block" do
      parser = SSE.new()

      chunk = """
      event: content_block_start
      data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_123","name":"get_weather","input":{}}}

      """

      {_parser, events} = SSE.feed(parser, chunk)

      assert length(events) == 1
      block = hd(events).data["content_block"]
      assert block["type"] == "tool_use"
      assert block["name"] == "get_weather"
      assert block["id"] == "toolu_123"
    end

    test "parses input_json_delta for tool arguments" do
      parser = SSE.new()

      chunk = """
      event: content_block_delta
      data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\\"location\\\": \\\"San"}}

      """

      {_parser, events} = SSE.feed(parser, chunk)

      assert length(events) == 1
      assert hd(events).data["delta"]["partial_json"] == "{\"location\": \"San"
    end

    test "parses error events" do
      parser = SSE.new()

      chunk = """
      event: error
      data: {"type":"error","error":{"type":"rate_limit_error","message":"Rate limited"}}

      """

      {_parser, events} = SSE.feed(parser, chunk)

      assert length(events) == 1
      event = hd(events)
      assert event.event == "error"
      assert event.data["error"]["type"] == "rate_limit_error"
      assert event.data["error"]["message"] == "Rate limited"
    end
  end

  describe "feed/2 with special content" do
    test "handles empty chunk" do
      parser = SSE.new()
      {parser, events} = SSE.feed(parser, "")
      assert events == []
      assert parser.buffer == ""
    end

    test "handles whitespace-only chunk" do
      parser = SSE.new()
      {_parser, events} = SSE.feed(parser, "   \n\n   ")
      assert events == []
    end

    test "handles nested JSON in data" do
      parser = SSE.new()

      chunk = """
      event: message_start
      data: {"type":"message_start","message":{"content":[{"type":"text","text":"{\\"nested\\": true}"}]}}

      """

      {_parser, events} = SSE.feed(parser, chunk)

      assert length(events) == 1
      content = hd(events).data["message"]["content"]
      assert hd(content)["text"] == "{\"nested\": true}"
    end

    test "handles unicode characters" do
      parser = SSE.new()

      chunk = """
      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello 世界"}}

      """

      {_parser, events} = SSE.feed(parser, chunk)

      assert length(events) == 1
      assert hd(events).data["delta"]["text"] == "Hello 世界"
    end

    test "handles large text content" do
      parser = SSE.new()
      long_text = String.duplicate("a", 10_000)

      chunk = """
      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"#{long_text}"}}

      """

      {parser, events} = SSE.feed(parser, chunk)

      assert parser.buffer == ""
      assert length(events) == 1
      assert String.length(hd(events).data["delta"]["text"]) == 10_000
    end
  end

  describe "flush/1" do
    test "returns empty for empty buffer" do
      parser = SSE.new()
      {parser, events} = SSE.flush(parser)
      assert events == []
      assert parser.buffer == ""
    end

    test "parses complete event without trailing delimiter" do
      parser = %SSE{buffer: "event: message_stop\ndata: {\"type\":\"message_stop\"}\n"}

      {parser, events} = SSE.flush(parser)

      assert length(events) == 1
      assert hd(events).event == "message_stop"
      assert parser.buffer == ""
    end

    test "discards incomplete JSON" do
      parser = %SSE{buffer: "event: partial\ndata: {incomplete json"}

      {parser, events} = SSE.flush(parser)

      assert events == []
      assert parser.buffer == ""
    end
  end

  describe "reset/1" do
    test "clears buffer" do
      parser = %SSE{buffer: "some buffered data"}
      parser = SSE.reset(parser)
      assert parser.buffer == ""
    end
  end

  describe "feed/2 with simulated network conditions" do
    test "handles rapid sequence of small chunks" do
      parser = SSE.new()

      events_data = [
        "event: message_start\ndata: {\"type\":\"start\"}\n\n",
        "event: content_block_start\ndata: {\"index\":0}\n\n",
        "event: content_block_delta\ndata: {\"text\":\"H\"}\n\n",
        "event: content_block_delta\ndata: {\"text\":\"i\"}\n\n",
        "event: content_block_stop\ndata: {\"index\":0}\n\n",
        "event: message_stop\ndata: {}\n\n"
      ]

      full_stream = Enum.join(events_data)
      chunks = chunk_randomly(full_stream)

      {_parser, all_events} =
        Enum.reduce(chunks, {parser, []}, fn chunk, {p, events} ->
          {new_p, new_events} = SSE.feed(p, chunk)
          {new_p, events ++ new_events}
        end)

      assert length(all_events) == 6
      assert Enum.at(all_events, 0).event == "message_start"
      assert Enum.at(all_events, 5).event == "message_stop"
    end
  end

  defp chunk_randomly(data) do
    chunk_randomly(data, [])
  end

  defp chunk_randomly("", acc), do: Enum.reverse(acc)

  defp chunk_randomly(data, acc) do
    size = min(:rand.uniform(50), byte_size(data))
    {chunk, rest} = String.split_at(data, size)
    chunk_randomly(rest, [chunk | acc])
  end
end
