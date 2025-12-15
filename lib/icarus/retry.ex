defmodule Icarus.Retry do
  @moduledoc """
  Retry logic with exponential backoff for Anthropic API.

  Handles:
  - Rate limits (429) with retry-after header
  - Server errors (500, 502, 503)
  - Overloaded (529) with longer backoff
  - Transport errors (timeout, connection closed)

  Does NOT retry:
  - Client errors (400, 401, 403, 404) - fix the request
  - Successful responses - obviously

  ## Usage

      Icarus.Retry.with_retry(fn ->
        make_request()
      end, max_retries: 3)

  ## Options

  - `:max_retries` - Maximum retry attempts (default: 3)
  - `:base_delay_ms` - Base delay in ms (default: 500)
  - `:max_delay_ms` - Maximum delay cap (default: 30_000)
  - `:on_retry` - Callback `fn attempt, delay, error -> :ok end`
  """

  alias Icarus.Error

  require Logger

  @default_max_retries 3
  @default_base_delay_ms 500
  @default_max_delay_ms 30_000

  @type opts :: [
          max_retries: non_neg_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          on_retry: (integer(), integer(), Error.t() -> :ok) | nil
        ]

  @doc """
  Execute function with retry logic.

  The function should return:
  - `{:ok, result}` - Success, return immediately
  - `{:error, %Icarus.Error{}}` - May retry based on error type
  """
  @spec with_retry((() -> {:ok, term()} | {:error, Error.t()}), opts()) ::
          {:ok, term()} | {:error, Error.t()}
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    do_retry(fun, 0, max_retries, opts)
  end

  @doc """
  Calculate delay for a given attempt.

  Uses exponential backoff with full jitter.
  """
  @spec calculate_delay(integer(), opts()) :: integer()
  def calculate_delay(attempt, opts \\ []) do
    base = Keyword.get(opts, :base_delay_ms, @default_base_delay_ms)
    max = Keyword.get(opts, :max_delay_ms, @default_max_delay_ms)
    exponential_with_jitter(base, attempt, max)
  end

  @doc """
  Calculate delay respecting retry-after header.
  """
  @spec calculate_delay_with_retry_after(Error.t() | nil, integer(), opts()) :: integer()
  def calculate_delay_with_retry_after(%Error{retry_after: retry_after}, _attempt, _opts)
      when is_integer(retry_after) and retry_after > 0 do
    retry_after
  end

  def calculate_delay_with_retry_after(%Error{type: :overloaded}, attempt, opts) do
    # 529 indicates severe load - double base delay to reduce pressure on API
    base = Keyword.get(opts, :base_delay_ms, @default_base_delay_ms) * 2
    max = Keyword.get(opts, :max_delay_ms, @default_max_delay_ms)
    exponential_with_jitter(base, attempt, max)
  end

  def calculate_delay_with_retry_after(_error, attempt, opts) do
    calculate_delay(attempt, opts)
  end

  # --- Private ---

  defp do_retry(fun, attempt, max_retries, opts) do
    case fun.() do
      {:ok, _} = success ->
        success

      {:error, %Error{} = error} ->
        if Error.retryable?(error) and attempt < max_retries do
          delay = calculate_delay_with_retry_after(error, attempt, opts)

          case Keyword.get(opts, :on_retry) do
            nil -> :ok
            callback when is_function(callback, 3) -> callback.(attempt + 1, delay, error)
          end

          Process.sleep(delay)
          do_retry(fun, attempt + 1, max_retries, opts)
        else
          error =
            if attempt >= max_retries do
              Error.mark_retries_exhausted(error)
            else
              error
            end

          {:error, error}
        end

      {:error, _} = error ->
        error
    end
  end

  defp exponential_with_jitter(base, attempt, max) do
    # Full jitter reduces thundering herd when many clients retry simultaneously
    delay = base * round(:math.pow(2, attempt))
    jitter = :rand.uniform(max(delay, 1))
    min(jitter, max)
  end
end
