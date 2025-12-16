defmodule Icarus do
  @moduledoc """
  Anthropic API client for Elixir with proper SSE streaming support.

  Icarus provides a robust interface to the Anthropic Claude API with:
  - Proper SSE buffering (fixes TCP chunking issues)
  - Typed events for easy pattern matching
  - Structured errors with retry information
  - Full support for thinking, tools, and streaming

  ## Setup

  1. Add Finch to your supervision tree:

      children = [
        {Finch, name: MyApp.Finch}
      ]

  2. Configure Icarus:

      config :icarus,
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        finch: MyApp.Finch

  ## Quick Start

      # Synchronous request
      {:ok, message} = Icarus.chat([
        %{role: "user", content: "Hello!"}
      ], model: "claude-sonnet-4-20250514")

      IO.puts(Icarus.Message.get_text(message))

      # Streaming request
      {:ok, pid} = Icarus.stream([
        %{role: "user", content: "Write a poem"}
      ], model: "claude-sonnet-4-20250514")

      receive_loop(pid)

      def receive_loop(pid) do
        receive do
          {:icarus, ^pid, {:event, %{type: :content_block_delta, delta: %{type: :text_delta, text: text}}}} ->
            IO.write(text)
            receive_loop(pid)

          {:icarus, ^pid, {:done, message}} ->
            IO.puts("\\nDone!")
            message

          {:icarus, ^pid, {:error, error}} ->
            IO.puts("Error: \#{error.message}")
        end
      end

  ## With Explicit Client

  For more control, create a client explicitly:

      client = Icarus.Client.new(
        api_key: "sk-ant-...",
        finch: MyApp.Finch,
        beta_features: ["interleaved-thinking-2025-05-14"]
      )

      {:ok, message} = Icarus.chat(client, messages, opts)
  """

  alias Icarus.{Client, Message, Error, Stream}

  @type message_input :: %{
          role: String.t(),
          content: String.t() | [map()]
        }

  @type chat_opts :: [
          model: String.t(),
          max_tokens: pos_integer(),
          system: String.t() | [map()],
          tools: [map()],
          thinking: map(),
          temperature: float(),
          top_p: float(),
          top_k: pos_integer(),
          stop_sequences: [String.t()],
          metadata: map()
        ]

  @type stream_opts :: [
          {:stream_to, pid()} | chat_opts_item()
        ]

  @typep chat_opts_item ::
           {:model, String.t()}
           | {:max_tokens, pos_integer()}
           | {:system, String.t() | [map()]}
           | {:tools, [map()]}
           | {:thinking, map()}
           | {:temperature, float()}

  # --- Public API ---

  @doc """
  Send a message and wait for complete response.

  ## Arguments

  - `messages` - List of message maps with `:role` and `:content`
  - `opts` - Request options (see below)

  Or with explicit client:
  - `client` - `%Icarus.Client{}`
  - `messages` - List of messages
  - `opts` - Request options

  ## Options

  - `:model` - Model ID (required, e.g., "claude-sonnet-4-20250514")
  - `:max_tokens` - Maximum tokens to generate (default: 1024)
  - `:system` - System prompt (string or content blocks)
  - `:tools` - Tool definitions
  - `:thinking` - Thinking configuration (e.g., `%{type: "enabled", budget_tokens: 1024}`)
  - `:temperature` - Sampling temperature (0.0-1.0)
  - `:top_p` - Nucleus sampling
  - `:top_k` - Top-k sampling
  - `:stop_sequences` - Stop sequences
  - `:metadata` - Request metadata

  ## Examples

      {:ok, message} = Icarus.chat([
        %{role: "user", content: "What is 2+2?"}
      ], model: "claude-sonnet-4-20250514")

      # With system prompt
      {:ok, message} = Icarus.chat([
        %{role: "user", content: "Hello"}
      ],
        model: "claude-sonnet-4-20250514",
        system: "You are a helpful assistant."
      )

      # With thinking enabled
      {:ok, message} = Icarus.chat([
        %{role: "user", content: "Solve this step by step..."}
      ],
        model: "claude-sonnet-4-20250514",
        thinking: %{type: "enabled", budget_tokens: 2048}
      )
  """
  @spec chat([message_input()], chat_opts()) :: {:ok, Message.t()} | {:error, Error.t()}
  @spec chat(Client.t(), [message_input()], chat_opts()) :: {:ok, Message.t()} | {:error, Error.t()}
  def chat(client_or_messages, messages_or_opts \\ [], opts \\ [])

  def chat(%Client{} = client, messages, opts) when is_list(messages) do
    body = build_request_body(messages, opts)

    case Client.request(client, body) do
      {:ok, response} ->
        {:ok, parse_response(response)}

      {:error, _} = error ->
        error
    end
  end

  def chat(messages, opts, _extra) when is_list(messages) and is_list(opts) do
    client = Client.new()
    chat(client, messages, opts)
  end

  @doc """
  Start a streaming conversation. Events sent to calling process.

  Returns `{:ok, pid}` where `pid` is the stream process. The pid can be used
  to cancel the stream with `Icarus.Stream.cancel(pid)`.

  ## Events

  - `{:icarus, pid, {:event, event}}` - Stream event
  - `{:icarus, pid, {:done, message}}` - Complete message
  - `{:icarus, pid, {:error, error}}` - Error occurred

  ## Options

  Same as `chat/2` plus:
  - `:stream_to` - PID to receive events (default: `self()`)

  ## Example

      {:ok, pid} = Icarus.stream([
        %{role: "user", content: "Tell me a story"}
      ], model: "claude-sonnet-4-20250514")

      def loop(pid) do
        receive do
          {:icarus, ^pid, {:event, event}} ->
            case event do
              %{type: :content_block_delta, delta: %{type: :text_delta, text: text}} ->
                IO.write(text)
              _ ->
                :ok
            end
            loop(pid)

          {:icarus, ^pid, {:done, _message}} ->
            :ok

          {:icarus, ^pid, {:error, error}} ->
            {:error, error}
        end
      end
  """
  @spec stream([message_input()], stream_opts()) :: {:ok, pid()} | {:error, Error.t()}
  @spec stream(Client.t(), [message_input()], stream_opts()) ::
          {:ok, pid()} | {:error, Error.t()}
  def stream(client_or_messages, messages_or_opts \\ [], opts \\ [])

  def stream(%Client{} = client, messages, opts) when is_list(messages) do
    {stream_opts, chat_opts} = Keyword.split(opts, [:stream_to])
    body = build_request_body(messages, chat_opts)
    Stream.start(client, body, stream_opts)
  end

  def stream(messages, opts, _extra) when is_list(messages) and is_list(opts) do
    client = Client.new()
    stream(client, messages, opts)
  end

  @doc """
  Create a new client with custom configuration.

  Shortcut for `Icarus.Client.new/1`.
  """
  @spec client(keyword()) :: Client.t()
  def client(opts \\ []) do
    Client.new(opts)
  end

  # --- Private ---

  defp build_request_body(messages, opts) do
    model = Keyword.get(opts, :model) || raise ArgumentError, "model is required"

    body = %{
      model: model,
      max_tokens: Keyword.get(opts, :max_tokens, 1024),
      messages: messages
    }

    body
    |> maybe_add(:system, Keyword.get(opts, :system))
    |> maybe_add(:tools, Keyword.get(opts, :tools))
    |> maybe_add(:thinking, Keyword.get(opts, :thinking))
    |> maybe_add(:temperature, Keyword.get(opts, :temperature))
    |> maybe_add(:top_p, Keyword.get(opts, :top_p))
    |> maybe_add(:top_k, Keyword.get(opts, :top_k))
    |> maybe_add(:stop_sequences, Keyword.get(opts, :stop_sequences))
    |> maybe_add(:metadata, Keyword.get(opts, :metadata))
  end

  defp maybe_add(body, _key, nil), do: body
  defp maybe_add(body, _key, []), do: body
  defp maybe_add(body, key, value), do: Map.put(body, key, value)

  defp parse_response(response) do
    content =
      (response["content"] || [])
      |> Enum.map(&parse_content_block/1)

    %Message{
      id: response["id"],
      type: response["type"],
      role: response["role"],
      model: response["model"],
      content: content,
      stop_reason: response["stop_reason"],
      stop_sequence: response["stop_sequence"],
      usage: %{
        input_tokens: get_in(response, ["usage", "input_tokens"]) || 0,
        output_tokens: get_in(response, ["usage", "output_tokens"]) || 0
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
    %{
      type: :thinking,
      thinking: block["thinking"] || "",
      signature: block["signature"]
    }
  end

  defp parse_content_block(block) do
    %{type: :unknown, raw: block}
  end
end
