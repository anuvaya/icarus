defmodule Icarus.Message do
  @moduledoc """
  Represents a complete message from Anthropic API.

  A message contains:
  - Metadata (id, model, role, usage)
  - Content blocks (text, tool_use, thinking)
  - Stop reason

  ## Content Blocks

  Content is a list of typed blocks:

      %Icarus.Message{
        content: [
          %{type: :thinking, thinking: "Let me analyze..."},
          %{type: :text, text: "Based on my analysis..."},
          %{type: :tool_use, id: "toolu_123", name: "get_weather", input: %{}}
        ]
      }
  """

  defstruct [
    :id,
    :type,
    :role,
    :model,
    :content,
    :stop_reason,
    :stop_sequence,
    :usage
  ]

  @type content_block ::
          text_block()
          | tool_use_block()
          | thinking_block()

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
          thinking: String.t(),
          signature: String.t() | nil
        }

  @type usage :: %{
          input_tokens: integer(),
          output_tokens: integer()
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          type: String.t() | nil,
          role: String.t() | nil,
          model: String.t() | nil,
          content: [content_block()],
          stop_reason: String.t() | nil,
          stop_sequence: String.t() | nil,
          usage: usage()
        }

  @doc """
  Create a new empty message.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      content: [],
      usage: %{input_tokens: 0, output_tokens: 0}
    }
  end

  @doc """
  Get all text content concatenated.
  """
  @spec get_text(t()) :: String.t()
  def get_text(%__MODULE__{content: content}) do
    content
    |> Enum.filter(&match?(%{type: :text}, &1))
    |> Enum.map(& &1.text)
    |> Enum.join("")
  end

  @doc """
  Get all thinking content concatenated.
  """
  @spec get_thinking(t()) :: String.t()
  def get_thinking(%__MODULE__{content: content}) do
    content
    |> Enum.filter(&match?(%{type: :thinking}, &1))
    |> Enum.map(& &1.thinking)
    |> Enum.join("")
  end

  @doc """
  Get all tool use blocks.
  """
  @spec get_tool_uses(t()) :: [tool_use_block()]
  def get_tool_uses(%__MODULE__{content: content}) do
    Enum.filter(content, &match?(%{type: :tool_use}, &1))
  end

  @doc """
  Check if message has any tool use.
  """
  @spec has_tool_use?(t()) :: boolean()
  def has_tool_use?(%__MODULE__{} = message) do
    get_tool_uses(message) != []
  end

  @doc """
  Check if message stopped due to tool use.
  """
  @spec tool_use_stop?(t()) :: boolean()
  def tool_use_stop?(%__MODULE__{stop_reason: "tool_use"}), do: true
  def tool_use_stop?(_), do: false
end

defmodule Icarus.Message.Accumulator do
  @moduledoc """
  Accumulates streaming events into a complete message.

  Used internally by `Icarus.Stream` to build the final message
  from streaming events.
  """

  alias Icarus.Message

  defstruct [
    :message,
    :content_blocks,
    :tool_json_acc
  ]

  @type t :: %__MODULE__{
          message: Message.t(),
          content_blocks: %{integer() => map()},
          tool_json_acc: %{integer() => String.t()}
        }

  @doc """
  Create a new accumulator.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      message: Message.new(),
      content_blocks: %{},
      tool_json_acc: %{}
    }
  end

  @doc """
  Apply a stream event to the accumulator.
  """
  @spec apply_event(t(), map()) :: t()
  def apply_event(%__MODULE__{} = acc, event) do
    case event do
      %{type: :message_start, message: msg_info} ->
        message = %{acc.message |
          id: msg_info.id,
          type: msg_info.type,
          role: msg_info.role,
          model: msg_info.model,
          usage: msg_info.usage
        }
        %{acc | message: message}

      %{type: :message_delta, delta: delta, usage: usage} ->
        message = %{acc.message |
          stop_reason: delta.stop_reason,
          stop_sequence: delta.stop_sequence,
          usage: %{
            input_tokens: acc.message.usage.input_tokens,
            output_tokens: usage.output_tokens
          }
        }
        %{acc | message: message}

      %{type: :content_block_start, index: index, content_block: block} ->
        content_blocks = Map.put(acc.content_blocks, index, block)
        %{acc | content_blocks: content_blocks}

      %{type: :content_block_delta, index: index, delta: delta} ->
        apply_delta(acc, index, delta)

      %{type: :content_block_stop, index: index} ->
        finalize_content_block(acc, index)

      _ ->
        acc
    end
  end

  @doc """
  Finalize the accumulator into a complete message.
  """
  @spec finalize(t()) :: Message.t()
  def finalize(%__MODULE__{} = acc) do
    content =
      acc.content_blocks
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.map(fn {_, block} -> block end)

    %{acc.message | content: content}
  end

  # --- Private ---

  defp apply_delta(acc, index, %{type: :text_delta, text: text}) do
    content_blocks =
      Map.update(acc.content_blocks, index, %{type: :text, text: text}, fn block ->
        %{block | text: (block[:text] || "") <> text}
      end)

    %{acc | content_blocks: content_blocks}
  end

  defp apply_delta(acc, index, %{type: :thinking_delta, thinking: thinking}) do
    content_blocks =
      Map.update(acc.content_blocks, index, %{type: :thinking, thinking: thinking}, fn block ->
        %{block | thinking: (block[:thinking] || "") <> thinking}
      end)

    %{acc | content_blocks: content_blocks}
  end

  defp apply_delta(acc, index, %{type: :signature_delta, signature: signature}) do
    content_blocks =
      Map.update(acc.content_blocks, index, %{type: :thinking, signature: signature}, fn block ->
        Map.put(block, :signature, (block[:signature] || "") <> signature)
      end)

    %{acc | content_blocks: content_blocks}
  end

  defp apply_delta(acc, index, %{type: :input_json_delta, partial_json: json}) do
    tool_json_acc =
      Map.update(acc.tool_json_acc, index, json, fn existing ->
        existing <> json
      end)

    %{acc | tool_json_acc: tool_json_acc}
  end

  defp apply_delta(acc, _index, _delta), do: acc

  defp finalize_content_block(acc, index) do
    case Map.get(acc.content_blocks, index) do
      %{type: :tool_use} = block ->
        json_str = Map.get(acc.tool_json_acc, index, "")

        input =
          case Jason.decode(json_str) do
            {:ok, parsed} -> parsed
            {:error, _} -> %{}
          end

        content_blocks = Map.put(acc.content_blocks, index, %{block | input: input})
        %{acc | content_blocks: content_blocks}

      _ ->
        acc
    end
  end
end
