defmodule Icarus.Event do
  @moduledoc """
  Typed representations of SSE stream events from Anthropic API.

  Instead of raw maps, events are converted to typed structs with atoms
  for easier pattern matching.

  ## Event Types

  - `:message_start` - Stream started, contains initial message metadata
  - `:message_delta` - Message-level updates (stop_reason, usage)
  - `:message_stop` - Stream complete
  - `:content_block_start` - New content block (text, tool_use, thinking)
  - `:content_block_delta` - Content updates (text_delta, input_json_delta, thinking_delta)
  - `:content_block_stop` - Content block complete
  - `:error` - Error during streaming
  - `:ping` - Keep-alive ping

  ## Example

      case event do
        %{type: :content_block_delta, delta: %{type: :text_delta, text: text}} ->
          IO.write(text)

        %{type: :content_block_delta, delta: %{type: :thinking_delta, thinking: thought}} ->
          Logger.debug("Thinking: \#{thought}")

        %{type: :error, error: error} ->
          Logger.error("Stream error: \#{error.message}")

        _ ->
          :ok
      end
  """

  # --- Event Types ---

  @type t ::
          message_start()
          | message_delta()
          | message_stop()
          | content_block_start()
          | content_block_delta()
          | content_block_stop()
          | error()
          | ping()
          | unknown()

  @type message_start :: %{
          type: :message_start,
          message: message_info()
        }

  @type message_delta :: %{
          type: :message_delta,
          delta: %{
            stop_reason: String.t() | nil,
            stop_sequence: String.t() | nil
          },
          usage: %{output_tokens: integer()}
        }

  @type message_stop :: %{type: :message_stop}

  @type content_block_start :: %{
          type: :content_block_start,
          index: non_neg_integer(),
          content_block: content_block()
        }

  @type content_block_delta :: %{
          type: :content_block_delta,
          index: non_neg_integer(),
          delta: delta()
        }

  @type content_block_stop :: %{
          type: :content_block_stop,
          index: non_neg_integer()
        }

  @type error :: %{
          type: :error,
          error: %{type: String.t(), message: String.t()}
        }

  @type ping :: %{type: :ping}

  @type unknown :: %{type: :unknown, raw: map()}

  # --- Supporting Types ---

  @type message_info :: %{
          id: String.t(),
          type: String.t(),
          role: String.t(),
          model: String.t(),
          content: [map()],
          stop_reason: String.t() | nil,
          stop_sequence: String.t() | nil,
          usage: %{
            input_tokens: integer(),
            output_tokens: integer()
          }
        }

  @type content_block ::
          text_block()
          | tool_use_block()
          | thinking_block()
          | unknown_block()

  @type text_block :: %{
          type: :text,
          text: String.t()
        }

  @type tool_use_block :: %{
          type: :tool_use,
          id: String.t(),
          name: String.t(),
          input: map()
        }

  @type thinking_block :: %{
          type: :thinking,
          thinking: String.t()
        }

  @type unknown_block :: %{
          type: :unknown,
          raw: map()
        }

  @type delta ::
          text_delta()
          | input_json_delta()
          | thinking_delta()
          | signature_delta()
          | unknown_delta()

  @type text_delta :: %{
          type: :text_delta,
          text: String.t()
        }

  @type input_json_delta :: %{
          type: :input_json_delta,
          partial_json: String.t()
        }

  @type thinking_delta :: %{
          type: :thinking_delta,
          thinking: String.t()
        }

  @type signature_delta :: %{
          type: :signature_delta,
          signature: String.t()
        }

  @type unknown_delta :: %{
          type: :unknown,
          raw: map()
        }

  # --- Public API ---

  @doc """
  Convert raw SSE event to typed struct.

  Takes the event name and data from SSE parser and returns
  a typed event map.
  """
  @spec from_sse(String.t(), map()) :: t()
  def from_sse("message_start", %{"message" => message}) do
    %{type: :message_start, message: parse_message_info(message)}
  end

  def from_sse("message_delta", data) do
    %{
      type: :message_delta,
      delta: %{
        stop_reason: get_in(data, ["delta", "stop_reason"]),
        stop_sequence: get_in(data, ["delta", "stop_sequence"])
      },
      usage: %{
        output_tokens: get_in(data, ["usage", "output_tokens"]) || 0
      }
    }
  end

  def from_sse("message_stop", _data) do
    %{type: :message_stop}
  end

  def from_sse("content_block_start", %{"index" => index, "content_block" => block}) do
    %{
      type: :content_block_start,
      index: index,
      content_block: parse_content_block(block)
    }
  end

  def from_sse("content_block_delta", %{"index" => index, "delta" => delta}) do
    %{
      type: :content_block_delta,
      index: index,
      delta: parse_delta(delta)
    }
  end

  def from_sse("content_block_stop", %{"index" => index}) do
    %{type: :content_block_stop, index: index}
  end

  def from_sse("error", %{"error" => error}) do
    %{
      type: :error,
      error: %{
        type: error["type"] || "unknown",
        message: error["message"] || "Unknown error"
      }
    }
  end

  def from_sse("ping", _data) do
    %{type: :ping}
  end

  def from_sse(_event_name, data) do
    %{type: :unknown, raw: data}
  end

  @doc """
  Check if event is a text delta.
  """
  @spec text_delta?(t()) :: boolean()
  def text_delta?(%{type: :content_block_delta, delta: %{type: :text_delta}}), do: true
  def text_delta?(_), do: false

  @doc """
  Check if event is a thinking delta.
  """
  @spec thinking_delta?(t()) :: boolean()
  def thinking_delta?(%{type: :content_block_delta, delta: %{type: :thinking_delta}}), do: true
  def thinking_delta?(_), do: false

  @doc """
  Check if event is a tool input delta.
  """
  @spec tool_input_delta?(t()) :: boolean()
  def tool_input_delta?(%{type: :content_block_delta, delta: %{type: :input_json_delta}}), do: true
  def tool_input_delta?(_), do: false

  @doc """
  Check if event is an error.
  """
  @spec error?(t()) :: boolean()
  def error?(%{type: :error}), do: true
  def error?(_), do: false

  @doc """
  Extract text from a text_delta event.
  Returns nil if not a text delta.
  """
  @spec get_text(t()) :: String.t() | nil
  def get_text(%{type: :content_block_delta, delta: %{type: :text_delta, text: text}}), do: text
  def get_text(_), do: nil

  @doc """
  Extract thinking from a thinking_delta event.
  Returns nil if not a thinking delta.
  """
  @spec get_thinking(t()) :: String.t() | nil
  def get_thinking(%{type: :content_block_delta, delta: %{type: :thinking_delta, thinking: thinking}}),
    do: thinking

  def get_thinking(_), do: nil

  # --- Private ---

  defp parse_message_info(message) do
    %{
      id: message["id"],
      type: message["type"],
      role: message["role"],
      model: message["model"],
      content: message["content"] || [],
      stop_reason: message["stop_reason"],
      stop_sequence: message["stop_sequence"],
      usage: %{
        input_tokens: get_in(message, ["usage", "input_tokens"]) || 0,
        output_tokens: get_in(message, ["usage", "output_tokens"]) || 0
      }
    }
  end

  defp parse_content_block(%{"type" => "text"} = block) do
    %{type: :text, text: block["text"] || ""}
  end

  defp parse_content_block(%{"type" => "tool_use"} = block) do
    %{
      type: :tool_use,
      id: block["id"],
      name: block["name"],
      input: block["input"] || %{}
    }
  end

  defp parse_content_block(%{"type" => "thinking"} = block) do
    %{type: :thinking, thinking: block["thinking"] || ""}
  end

  defp parse_content_block(block) do
    %{type: :unknown, raw: block}
  end

  defp parse_delta(%{"type" => "text_delta"} = delta) do
    %{type: :text_delta, text: delta["text"] || ""}
  end

  defp parse_delta(%{"type" => "input_json_delta"} = delta) do
    %{type: :input_json_delta, partial_json: delta["partial_json"] || ""}
  end

  defp parse_delta(%{"type" => "thinking_delta"} = delta) do
    %{type: :thinking_delta, thinking: delta["thinking"] || ""}
  end

  defp parse_delta(%{"type" => "signature_delta"} = delta) do
    %{type: :signature_delta, signature: delta["signature"] || ""}
  end

  defp parse_delta(delta) do
    %{type: :unknown, raw: delta}
  end
end
