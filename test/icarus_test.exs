defmodule IcarusTest do
  use ExUnit.Case

  alias Icarus.{Client, Message, Error}

  describe "client/1" do
    test "creates client with options" do
      client = Icarus.client(
        api_key: "test-key",
        finch: TestFinch,
        max_retries: 5
      )

      assert %Client{} = client
      assert client.api_key == "test-key"
      assert client.finch == TestFinch
      assert client.max_retries == 5
    end
  end

  describe "Message" do
    test "get_text extracts all text content" do
      message = %Message{
        content: [
          %{type: :thinking, thinking: "hmm"},
          %{type: :text, text: "Hello "},
          %{type: :text, text: "World"}
        ],
        usage: %{input_tokens: 0, output_tokens: 0}
      }

      assert Message.get_text(message) == "Hello World"
    end

    test "get_thinking extracts thinking content" do
      message = %Message{
        content: [
          %{type: :thinking, thinking: "Let me think..."},
          %{type: :text, text: "Here's my answer"}
        ],
        usage: %{input_tokens: 0, output_tokens: 0}
      }

      assert Message.get_thinking(message) == "Let me think..."
    end

    test "get_tool_uses extracts tool blocks" do
      message = %Message{
        content: [
          %{type: :text, text: "I'll check the weather"},
          %{type: :tool_use, id: "toolu_1", name: "get_weather", input: %{"city" => "NYC"}}
        ],
        usage: %{input_tokens: 0, output_tokens: 0}
      }

      tools = Message.get_tool_uses(message)
      assert length(tools) == 1
      assert hd(tools).name == "get_weather"
    end

    test "has_tool_use? returns true when tools present" do
      message = %Message{
        content: [
          %{type: :tool_use, id: "1", name: "test", input: %{}}
        ],
        usage: %{input_tokens: 0, output_tokens: 0}
      }

      assert Message.has_tool_use?(message)
    end

    test "tool_use_stop? checks stop reason" do
      message = %Message{
        stop_reason: "tool_use",
        content: [],
        usage: %{input_tokens: 0, output_tokens: 0}
      }

      assert Message.tool_use_stop?(message)
    end
  end

  describe "Error" do
    test "from_response parses error body" do
      body = ~s({"error": {"type": "rate_limit_error", "message": "Too many requests"}})
      headers = [{"x-request-id", "req_123"}, {"retry-after", "30"}]

      error = Error.from_response(429, body, headers)

      assert error.type == :rate_limit
      assert error.status == 429
      assert error.message == "Too many requests"
      assert error.request_id == "req_123"
      assert error.retry_after == 30_000  # converted to ms
    end

    test "from_transport creates transport error" do
      error = Error.from_transport(:timeout)

      assert error.type == :transport
      assert error.message =~ "timeout"
    end

    test "retryable? returns true for appropriate types" do
      assert Error.retryable?(%Error{type: :rate_limit})
      assert Error.retryable?(%Error{type: :api_error})
      assert Error.retryable?(%Error{type: :overloaded})
      assert Error.retryable?(%Error{type: :transport})
      refute Error.retryable?(%Error{type: :invalid_request})
      refute Error.retryable?(%Error{type: :authentication})
    end
  end
end
