# Icarus

A robust, streaming-first Anthropic API client for Elixir with proper SSE handling.

## Why Icarus?

Built from the ground up for robust streaming:

- **Proper SSE buffering** - Handles TCP chunking correctly
- **Typed events** - Pattern match on atoms, not strings
- **Structured errors** - Know exactly what went wrong and whether to retry
- **First-class streaming** - Designed for real-time AI chat applications

## Installation

```elixir
def deps do
  [
    {:icarus, "~> 0.1.0"},
    {:finch, "~> 0.19"}
  ]
end
```

## Setup

1. Add Finch to your supervision tree:

```elixir
children = [
  {Finch, name: MyApp.Finch}
]
```

2. Configure Icarus:

```elixir
# config/config.exs
config :icarus,
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  finch: MyApp.Finch
```

## Quick Start

### Synchronous Request

```elixir
{:ok, message} = Icarus.chat([
  %{role: "user", content: "What is the capital of France?"}
], model: "claude-sonnet-4-20250514")

IO.puts(Icarus.Message.get_text(message))
# => "The capital of France is Paris."
```

### Streaming Request

```elixir
{:ok, ref} = Icarus.stream([
  %{role: "user", content: "Write a haiku about Elixir"}
], model: "claude-sonnet-4-20250514")

defp receive_loop(ref) do
  receive do
    {:icarus, ^ref, {:event, event}} ->
      case event do
        %{type: :content_block_delta, delta: %{type: :text_delta, text: text}} ->
          IO.write(text)
        _ ->
          :ok
      end
      receive_loop(ref)

    {:icarus, ^ref, {:done, message}} ->
      IO.puts("\n--- Done! ---")
      message

    {:icarus, ^ref, {:error, error}} ->
      IO.puts("Error: #{error.message}")
  end
end
```

### With Thinking Enabled

```elixir
client = Icarus.client(
  api_key: "sk-ant-...",
  finch: MyApp.Finch,
  beta_features: ["interleaved-thinking-2025-05-14"]
)

{:ok, ref} = Icarus.stream(client, [
  %{role: "user", content: "Solve: If x + 5 = 12, what is x?"}
],
  model: "claude-sonnet-4-20250514",
  thinking: %{type: "enabled", budget_tokens: 1024}
)

# Receive thinking + text deltas
```

### With Tools

```elixir
tools = [
  %{
    name: "get_weather",
    description: "Get weather for a location",
    input_schema: %{
      type: "object",
      properties: %{
        location: %{type: "string", description: "City name"}
      },
      required: ["location"]
    }
  }
]

{:ok, message} = Icarus.chat([
  %{role: "user", content: "What's the weather in Tokyo?"}
],
  model: "claude-sonnet-4-20250514",
  tools: tools
)

if Icarus.Message.has_tool_use?(message) do
  tool_uses = Icarus.Message.get_tool_uses(message)
  # Execute tools and continue conversation
end
```

## Event Types

When streaming, you receive typed events:

| Event | Description |
|-------|-------------|
| `%{type: :message_start}` | Stream started |
| `%{type: :content_block_start}` | New content block (text, tool_use, thinking) |
| `%{type: :content_block_delta}` | Content update |
| `%{type: :content_block_stop}` | Block complete |
| `%{type: :message_delta}` | Message-level update (stop_reason) |
| `%{type: :message_stop}` | Stream complete |
| `%{type: :error}` | Error during stream |

### Delta Types

```elixir
%{type: :content_block_delta, delta: %{type: :text_delta, text: "..."}}
%{type: :content_block_delta, delta: %{type: :thinking_delta, thinking: "..."}}
%{type: :content_block_delta, delta: %{type: :input_json_delta, partial_json: "..."}}
%{type: :content_block_delta, delta: %{type: :signature_delta, signature: "..."}}
```

## Error Handling

Icarus provides structured errors:

```elixir
case Icarus.chat(messages, model: "claude-sonnet-4-20250514") do
  {:ok, message} ->
    message

  {:error, %Icarus.Error{type: :rate_limit} = error} ->
    # Retry after delay
    Process.sleep(error.retry_after || 5000)
    retry()

  {:error, %Icarus.Error{type: :authentication}} ->
    raise "Invalid API key"

  {:error, %Icarus.Error{type: :invalid_request, message: msg}} ->
    Logger.error("Bad request: #{msg}")
end
```

### Error Types

| Type | Status | Retryable |
|------|--------|-----------|
| `:invalid_request` | 400 | No |
| `:authentication` | 401 | No |
| `:permission` | 403 | No |
| `:not_found` | 404 | No |
| `:rate_limit` | 429 | Yes |
| `:api_error` | 500 | Yes |
| `:overloaded` | 529 | Yes |
| `:transport` | - | Yes |

## Configuration Options

```elixir
client = Icarus.client(
  api_key: "sk-ant-...",           # Required
  finch: MyApp.Finch,               # Required
  base_url: "https://api.anthropic.com",  # Default
  max_retries: 3,                   # Default
  base_delay_ms: 500,               # Default retry delay
  max_delay_ms: 30_000,             # Max retry delay
  connect_timeout: 5_000,           # Connection timeout
  receive_timeout: 120_000,         # Response timeout
  beta_features: []                 # Beta feature flags
)
```

## Architecture

```
Icarus (Public API)
    │
    ├── Icarus.Client (HTTP transport via Finch)
    │       │
    │       └── Icarus.Retry (Exponential backoff)
    │
    ├── Icarus.Stream (Streaming orchestrator)
    │       │
    │       ├── Icarus.SSE (Stateful parser with buffering)
    │       │
    │       └── Icarus.Message.Accumulator (Builds final message)
    │
    ├── Icarus.Event (Typed stream events)
    ├── Icarus.Message (Response structs)
    └── Icarus.Error (Structured errors)
```

## License

MIT
