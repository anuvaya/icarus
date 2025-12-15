defmodule Icarus.Stream do
  @moduledoc """
  Manages streaming lifecycle and message delivery.

  This module coordinates:
  1. Starting the HTTP stream
  2. Feeding chunks to SSE parser
  3. Converting SSE events to typed structs
  4. Accumulating the final message
  5. Sending events to the caller

  ## Usage

  Start a stream and receive events as messages:

      {:ok, ref} = Icarus.Stream.start(client, request_body, stream_to: self())

      receive do
        {:icarus, ^ref, {:event, event}} ->
          # Handle streaming event
          case event do
            %{type: :content_block_delta, delta: %{type: :text_delta, text: text}} ->
              IO.write(text)
            _ ->
              :ok
          end

        {:icarus, ^ref, {:done, message}} ->
          # Stream complete, message has full content

        {:icarus, ^ref, {:error, error}} ->
          # Handle error
      end

  ## Message Types

  - `{:icarus, ref, {:event, %Icarus.Event{}}}` - Stream event
  - `{:icarus, ref, {:done, %Icarus.Message{}}}` - Complete message
  - `{:icarus, ref, {:error, %Icarus.Error{}}}` - Error occurred
  """

  use GenServer

  alias Icarus.{SSE, Client, Event, Error}

  require Logger

  defstruct [
    :ref,
    :client,
    :request_body,
    :stream_to,
    :sse_parser,
    :message_acc,
    :status,
    :task
  ]

  @type stream_opts :: [
          stream_to: pid()
        ]

  # --- Public API ---

  @doc """
  Start a new stream. Returns immediately with a reference.

  Events will be sent to `stream_to` (defaults to caller).

  ## Options

  - `:stream_to` - PID to receive events (default: `self()`)
  """
  @spec start(Client.t(), map(), stream_opts()) :: {:ok, reference()} | {:error, Error.t()}
  def start(%Client{} = client, request_body, opts \\ []) do
    ref = make_ref()
    stream_to = Keyword.get(opts, :stream_to, self())

    case GenServer.start(__MODULE__, %{
           ref: ref,
           client: client,
           request_body: request_body,
           stream_to: stream_to
         }) do
      {:ok, pid} ->
        # Link so stream dies if caller dies (prevents orphan streams)
        Process.link(pid)
        {:ok, ref}

      {:error, reason} ->
        {:error, Error.from_transport(reason)}
    end
  end

  @doc """
  Start a stream linked to the current process.

  Same as `start/3` but explicitly links to caller.
  """
  @spec start_link(Client.t(), map(), stream_opts()) :: {:ok, reference()} | {:error, Error.t()}
  def start_link(client, request_body, opts \\ []) do
    start(client, request_body, opts)
  end

  @doc """
  Cancel an in-progress stream.
  """
  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    GenServer.stop(pid, :cancelled)
  catch
    :exit, _ -> :ok
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(args) do
    state = %__MODULE__{
      ref: args.ref,
      client: args.client,
      request_body: args.request_body,
      stream_to: args.stream_to,
      sse_parser: SSE.new(),
      message_acc: Icarus.Message.Accumulator.new(),
      status: :connecting
    }

    # Use continue to avoid blocking supervision tree startup
    {:ok, state, {:continue, :start_stream}}
  end

  @impl true
  def handle_continue(:start_stream, state) do
    parent = self()

    task =
      Task.async(fn ->
        Client.stream_request(state.client, state.request_body, fn
          {:data, chunk} -> send(parent, {:chunk, chunk})
          :done -> send(parent, :stream_done)
        end)
      end)

    {:noreply, %{state | task: task, status: :streaming}}
  end

  @impl true
  def handle_info({:chunk, chunk}, state) do
    {parser, events} = SSE.feed(state.sse_parser, chunk)

    state = %{state | sse_parser: parser}
    state = process_events(state, events)

    {:noreply, state}
  end

  @impl true
  def handle_info(:stream_done, state) do
    {parser, final_events} = SSE.flush(state.sse_parser)
    state = %{state | sse_parser: parser}
    state = process_events(state, final_events)

    message = Icarus.Message.Accumulator.finalize(state.message_acc)
    send(state.stream_to, {:icarus, state.ref, {:done, message}})

    {:stop, :normal, state}
  end

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: task_ref}} = state)
      when ref == task_ref do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, _} ->
        {:noreply, state}

      {:error, %Error{} = error} ->
        send(state.stream_to, {:icarus, state.ref, {:error, error}})
        {:stop, :normal, state}

      {:error, reason} ->
        error = Error.from_transport(reason)
        send(state.stream_to, {:icarus, state.ref, {:error, error}})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: task_ref}} = state)
      when ref == task_ref do
    if reason != :normal do
      error = Error.from_transport(reason)
      send(state.stream_to, {:icarus, state.ref, {:error, error}})
    end

    {:stop, :normal, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{task: %Task{} = task}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Private ---

  defp process_events(state, events) do
    Enum.reduce(events, state, fn %{event: event_type, data: data}, state ->
      event = Event.from_sse(event_type, data)

      case event do
        %{type: :error} ->
          error = Error.from_sse_event(data)
          send(state.stream_to, {:icarus, state.ref, {:error, error}})
          state

        _ ->
          send(state.stream_to, {:icarus, state.ref, {:event, event}})
          message_acc = Icarus.Message.Accumulator.apply_event(state.message_acc, event)
          %{state | message_acc: message_acc}
      end
    end)
  end
end
