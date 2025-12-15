defmodule Icarus.SSE do
  @moduledoc """
  Stateful Server-Sent Events parser with buffering.

  This parser handles SSE streams where events may be split across
  multiple TCP chunks. Data is buffered until complete events
  (terminated by double newline) are found.

  ## SSE Format

  SSE events are formatted as:

      event: message_start
      data: {"type": "message_start", "message": {...}}

      event: content_block_delta
      data: {"type": "content_block_delta", ...}

  Events are separated by blank lines (`\\n\\n`).

  ## TCP Chunking

  TCP doesn't guarantee chunk boundaries align with SSE events.
  A single event might arrive as:

      Chunk 1: "event: message_start\\ndata: {\\"type\\": \\"mes"
      Chunk 2: "sage_start\\", \\"message\\": {...}}\\n\\n"

  This parser buffers until `\\n\\n` is found, then parses complete events.

  ## Usage

      parser = Icarus.SSE.new()

      # Feed chunks as they arrive from HTTP stream
      {parser, events} = Icarus.SSE.feed(parser, chunk1)
      {parser, more_events} = Icarus.SSE.feed(parser, chunk2)

      # When stream ends, flush any remaining data
      {_parser, final_events} = Icarus.SSE.flush(parser)
  """

  defstruct buffer: ""

  @type t :: %__MODULE__{
          buffer: String.t()
        }

  @type event :: %{
          event: String.t(),
          data: map()
        }

  @event_delimiter "\n\n"
  @event_line_regex ~r/^event:\s*(.+)$/m
  @data_line_regex ~r/^data:\s*(.*)$/m

  @doc """
  Create a new SSE parser state.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feed a chunk of data into the parser.

  Returns `{updated_parser, complete_events}` where:
  - `updated_parser` has any incomplete data buffered
  - `complete_events` is a list of fully parsed events

  ## Example

      parser = Icarus.SSE.new()

      {parser, []} = Icarus.SSE.feed(parser, "event: message_start\\ndata: {\\"ty")
      # No complete events yet, data buffered

      {parser, [event]} = Icarus.SSE.feed(parser, "pe\\": \\"message_start\\"}\\n\\n")
      # Now we have a complete event
  """
  @spec feed(t(), binary()) :: {t(), [event()]}
  def feed(%__MODULE__{buffer: buffer} = parser, chunk) when is_binary(chunk) do
    combined = buffer <> chunk
    {events, remaining} = extract_complete_events(combined)
    {%{parser | buffer: remaining}, events}
  end

  @doc """
  Flush any remaining data in the buffer.

  Call this when the stream ends to handle any trailing data.
  Returns `{empty_parser, final_events}`.
  """
  @spec flush(t()) :: {t(), [event()]}
  def flush(%__MODULE__{buffer: buffer} = parser) do
    trimmed = String.trim(buffer)

    if trimmed == "" do
      {%{parser | buffer: ""}, []}
    else
      case parse_event_block(buffer) do
        {:ok, event} -> {%{parser | buffer: ""}, [event]}
        :incomplete -> {%{parser | buffer: ""}, []}
        :skip -> {%{parser | buffer: ""}, []}
      end
    end
  end

  @doc """
  Reset the parser, clearing any buffered data.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = _parser), do: %__MODULE__{}

  # --- Private Implementation ---

  defp extract_complete_events(data) do
    case :binary.matches(data, @event_delimiter) do
      [] ->
        {[], data}

      matches ->
        {last_pos, len} = List.last(matches)
        split_at = last_pos + len

        complete_part = binary_part(data, 0, split_at)
        remaining = binary_part(data, split_at, byte_size(data) - split_at)

        events =
          complete_part
          |> String.split(@event_delimiter, trim: true)
          |> Enum.map(&parse_event_block/1)
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(fn {:ok, event} -> event end)

        {events, remaining}
    end
  end

  defp parse_event_block(block) do
    event_name =
      case Regex.run(@event_line_regex, block) do
        [_, name] -> String.trim(name)
        _ -> nil
      end

    # SSE spec allows multiple data: lines which should be joined with newlines
    data_lines =
      @data_line_regex
      |> Regex.scan(block)
      |> Enum.map(fn [_, data] -> data end)
      |> Enum.join("\n")

    cond do
      event_name == "ping" ->
        {:ok, %{event: "ping", data: %{}}}

      event_name && data_lines != "" ->
        case Jason.decode(data_lines) do
          {:ok, data} -> {:ok, %{event: event_name, data: data}}
          {:error, _} -> :incomplete
        end

      event_name && data_lines == "" ->
        :incomplete

      true ->
        :skip
    end
  end
end
