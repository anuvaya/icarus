defmodule Icarus.Client do
  @moduledoc """
  HTTP client for Anthropic API using Finch.

  This module handles:
  - Request building with proper headers
  - Non-streaming requests with retry
  - Streaming requests with chunk callbacks

  ## Setup

  Add Finch to your supervision tree:

      children = [
        {Finch, name: MyApp.Finch}
      ]

  Or with tuned settings for Anthropic:

      children = [
        {Finch,
          name: MyApp.Finch,
          pools: %{
            "https://api.anthropic.com" => [
              size: 10,
              count: 2,
              protocol: :http2
            ]
          }
        }
      ]

  ## Usage

      client = Icarus.Client.new(
        api_key: "sk-ant-...",
        finch: MyApp.Finch
      )

      {:ok, response} = Icarus.Client.request(client, %{
        model: "claude-sonnet-4-20250514",
        max_tokens: 1024,
        messages: [%{role: "user", content: "Hello"}]
      })
  """

  alias Icarus.{Error, Retry}

  @default_base_url "https://api.anthropic.com"
  @api_version "2023-06-01"

  defstruct [
    :api_key,
    :finch,
    :base_url,
    :default_model,
    :max_retries,
    :base_delay_ms,
    :max_delay_ms,
    :connect_timeout,
    :receive_timeout,
    :beta_features
  ]

  @type t :: %__MODULE__{
          api_key: String.t(),
          finch: atom(),
          base_url: String.t(),
          default_model: String.t() | nil,
          max_retries: non_neg_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          connect_timeout: pos_integer(),
          receive_timeout: pos_integer(),
          beta_features: [String.t()]
        }

  @type request_opts :: [
          api_key: String.t(),
          finch: atom(),
          base_url: String.t(),
          default_model: String.t(),
          max_retries: non_neg_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          connect_timeout: pos_integer(),
          receive_timeout: pos_integer(),
          beta_features: [String.t()]
        ]

  @doc """
  Create a new client with configuration.

  ## Options

  - `:api_key` - Anthropic API key (required, or set ANTHROPIC_API_KEY env)
  - `:finch` - Finch pool name (required)
  - `:base_url` - API base URL (default: https://api.anthropic.com)
  - `:default_model` - Default model for requests
  - `:max_retries` - Max retry attempts (default: 3)
  - `:base_delay_ms` - Base retry delay (default: 500)
  - `:max_delay_ms` - Max retry delay (default: 30000)
  - `:connect_timeout` - Connection timeout (default: 5000)
  - `:receive_timeout` - Response timeout (default: 120000)
  - `:beta_features` - List of beta feature strings
  """
  @spec new(request_opts()) :: t()
  def new(opts \\ []) do
    api_key = Keyword.get(opts, :api_key) || get_api_key!()
    finch = Keyword.get_lazy(opts, :finch, fn -> get_finch!() end)

    %__MODULE__{
      api_key: api_key,
      finch: finch,
      base_url: Keyword.get(opts, :base_url, @default_base_url),
      default_model: Keyword.get(opts, :default_model),
      max_retries: Keyword.get(opts, :max_retries, 3),
      base_delay_ms: Keyword.get(opts, :base_delay_ms, 500),
      max_delay_ms: Keyword.get(opts, :max_delay_ms, 30_000),
      connect_timeout: Keyword.get(opts, :connect_timeout, 5_000),
      receive_timeout: Keyword.get(opts, :receive_timeout, 120_000),
      beta_features: Keyword.get(opts, :beta_features, [])
    }
  end

  @doc """
  Make a non-streaming request to the messages API.

  Automatically retries on transient errors.
  """
  @spec request(t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def request(%__MODULE__{} = client, body) do
    finch_request = build_request(client, body)
    retry_opts = retry_opts(client)

    Retry.with_retry(
      fn -> do_request(client, finch_request) end,
      retry_opts
    )
  end

  @doc """
  Start a streaming request. Calls `callback` for each data chunk.

  The callback receives:
  - `{:data, binary()}` - Raw SSE data chunk
  - `:done` - Stream complete

  Returns `{:ok, acc}` or `{:error, %Icarus.Error{}}`.

  Note: Streaming requests are NOT automatically retried after first chunk.
  Retry only happens if connection fails before any data is received.
  """
  @spec stream_request(t(), map(), ({:data, binary()} | :done -> term())) ::
          {:ok, term()} | {:error, Error.t()}
  def stream_request(%__MODULE__{} = client, body, callback) when is_function(callback, 1) do
    body = Map.put(body, :stream, true)
    finch_request = build_request(client, body)

    do_stream_request(client, finch_request, callback)
  end

  @doc """
  Build headers for Anthropic API request.
  """
  @spec build_headers(t()) :: [{String.t(), String.t()}]
  def build_headers(%__MODULE__{} = client) do
    headers = [
      {"content-type", "application/json"},
      {"x-api-key", client.api_key},
      {"anthropic-version", @api_version}
    ]

    if client.beta_features != [] do
      beta_header = Enum.join(client.beta_features, ",")
      [{"anthropic-beta", beta_header} | headers]
    else
      headers
    end
  end

  # --- Private ---

  defp build_request(%__MODULE__{} = client, body) do
    url = client.base_url <> "/v1/messages"
    headers = build_headers(client)
    encoded_body = Jason.encode!(body)

    Finch.build(:post, url, headers, encoded_body)
  end

  defp do_request(%__MODULE__{} = client, request) do
    opts = [receive_timeout: client.receive_timeout]

    case Finch.request(request, client.finch, opts) do
      {:ok, %Finch.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, Error.from_response(status, body, headers)}
        end

      {:ok, %Finch.Response{status: status, body: body, headers: headers}} ->
        {:error, Error.from_response(status, body, headers)}

      {:error, reason} ->
        {:error, Error.from_transport(reason)}
    end
  end

  defp do_stream_request(%__MODULE__{} = client, request, callback) do
    acc = %{
      status: nil,
      headers: [],
      body_acc: [],
      first_chunk_received: false
    }

    stream_opts = [receive_timeout: client.receive_timeout]

    result =
      Finch.stream(
        request,
        client.finch,
        acc,
        fn
          {:status, status}, acc ->
            %{acc | status: status}

          {:headers, headers}, acc ->
            %{acc | headers: headers}

          {:data, chunk}, acc ->
            if acc.status in 200..299 do
              callback.({:data, chunk})
              %{acc | first_chunk_received: true}
            else
              %{acc | body_acc: [chunk | acc.body_acc]}
            end
        end,
        stream_opts
      )

    case result do
      {:ok, %{status: status} = acc} when status in 200..299 ->
        callback.(:done)
        {:ok, acc}

      {:ok, %{status: status, body_acc: body_parts, headers: headers}} ->
        body = body_parts |> Enum.reverse() |> IO.iodata_to_binary()
        {:error, Error.from_response(status, body, headers)}

      {:error, reason} ->
        {:error, Error.from_transport(reason)}
    end
  end

  defp retry_opts(%__MODULE__{} = client) do
    [
      max_retries: client.max_retries,
      base_delay_ms: client.base_delay_ms,
      max_delay_ms: client.max_delay_ms
    ]
  end

  defp get_api_key! do
    case Application.get_env(:icarus, :api_key) || System.get_env("ANTHROPIC_API_KEY") do
      nil ->
        raise ArgumentError, """
        Missing Anthropic API key.

        Either:
        1. Pass `api_key: "sk-ant-..."` to Icarus.Client.new/1
        2. Set config :icarus, :api_key
        3. Set ANTHROPIC_API_KEY environment variable
        """

      key ->
        key
    end
  end

  defp get_finch! do
    case Application.get_env(:icarus, :finch) do
      nil ->
        raise ArgumentError, """
        Missing Finch pool name.

        Either:
        1. Pass `finch: MyApp.Finch` to Icarus.Client.new/1
        2. Set config :icarus, :finch

        Make sure to start Finch in your supervision tree:

            children = [
              {Finch, name: MyApp.Finch}
            ]
        """

      finch ->
        finch
    end
  end
end
