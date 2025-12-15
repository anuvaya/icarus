defmodule Icarus.Error do
  @moduledoc """
  Structured error type for Anthropic API errors.

  Provides clear error types and messages instead of opaque failures.

  ## Error Types

  - `:invalid_request` - Bad request (400)
  - `:authentication` - Invalid API key (401)
  - `:permission` - Access denied (403)
  - `:not_found` - Resource not found (404)
  - `:rate_limit` - Rate limited (429)
  - `:api_error` - Server error (500)
  - `:overloaded` - API overloaded (529)
  - `:transport` - Connection/network error
  - `:stream_error` - Error during SSE stream
  - `:unknown` - Unrecognized error

  ## Example

      case Icarus.chat(messages) do
        {:ok, message} ->
          message

        {:error, %Icarus.Error{type: :rate_limit} = error} ->
          Logger.warning("Rate limited: \#{error.message}")
          Process.sleep(error.retry_after || 5000)
          retry()

        {:error, %Icarus.Error{type: :authentication}} ->
          raise "Invalid API key"
      end
  """

  defexception [
    :type,
    :status,
    :message,
    :request_id,
    :headers,
    :retry_after,
    :retries_exhausted
  ]

  @type error_type ::
          :invalid_request
          | :authentication
          | :permission
          | :not_found
          | :rate_limit
          | :api_error
          | :overloaded
          | :transport
          | :stream_error
          | :unknown

  @type t :: %__MODULE__{
          type: error_type(),
          status: integer() | nil,
          message: String.t(),
          request_id: String.t() | nil,
          headers: [{String.t(), String.t()}],
          retry_after: integer() | nil,
          retries_exhausted: boolean()
        }

  @impl true
  def message(%__MODULE__{} = error) do
    status_str = if error.status, do: " (#{error.status})", else: ""
    retry_str = if error.retries_exhausted, do: " [retries exhausted]", else: ""
    req_id_str = if error.request_id, do: " [#{error.request_id}]", else: ""
    "#{error.type}#{status_str}: #{error.message}#{retry_str}#{req_id_str}"
  end

  @doc """
  Create error from HTTP response.
  """
  @spec from_response(integer(), binary(), [{String.t(), String.t()}]) :: t()
  def from_response(status, body, headers) do
    {type, message} = parse_error_body(status, body)
    request_id = get_header(headers, "x-request-id")
    retry_after = parse_retry_after(headers)

    %__MODULE__{
      type: type,
      status: status,
      message: message,
      request_id: request_id,
      headers: headers,
      retry_after: retry_after,
      retries_exhausted: false
    }
  end

  @doc """
  Create error from transport/connection issue.
  """
  @spec from_transport(term()) :: t()
  def from_transport(reason) do
    message = format_transport_error(reason)

    %__MODULE__{
      type: :transport,
      status: nil,
      message: message,
      request_id: nil,
      headers: [],
      retry_after: nil,
      retries_exhausted: false
    }
  end

  @doc """
  Create error from SSE error event.
  """
  @spec from_sse_event(map()) :: t()
  def from_sse_event(%{"type" => type, "message" => message}) do
    %__MODULE__{
      type: sse_type_to_atom(type),
      status: nil,
      message: message,
      request_id: nil,
      headers: [],
      retry_after: nil,
      retries_exhausted: false
    }
  end

  def from_sse_event(%{"error" => %{"type" => type, "message" => message}}) do
    %__MODULE__{
      type: sse_type_to_atom(type),
      status: nil,
      message: message,
      request_id: nil,
      headers: [],
      retry_after: nil,
      retries_exhausted: false
    }
  end

  @doc """
  Check if this error type is retryable.
  """
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{type: type}) do
    type in [:rate_limit, :api_error, :overloaded, :transport]
  end

  @doc """
  Check if this error type is retryable based on status.
  """
  @spec retryable_status?(integer()) :: boolean()
  def retryable_status?(status) when status in [429, 500, 502, 503, 529], do: true
  def retryable_status?(_), do: false

  @doc """
  Mark error as having exhausted retries.
  """
  @spec mark_retries_exhausted(t()) :: t()
  def mark_retries_exhausted(%__MODULE__{} = error) do
    %{error | retries_exhausted: true}
  end

  # --- Private ---

  defp parse_error_body(status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"type" => type, "message" => message}}} ->
        {type_from_string(type), message}

      {:ok, %{"type" => "error", "error" => %{"type" => type, "message" => message}}} ->
        {type_from_string(type), message}

      _ ->
        {type_from_status(status), body_or_default(body, status)}
    end
  end

  defp parse_error_body(status, _body) do
    {type_from_status(status), default_message(status)}
  end

  defp type_from_string("invalid_request_error"), do: :invalid_request
  defp type_from_string("authentication_error"), do: :authentication
  defp type_from_string("permission_error"), do: :permission
  defp type_from_string("not_found_error"), do: :not_found
  defp type_from_string("rate_limit_error"), do: :rate_limit
  defp type_from_string("api_error"), do: :api_error
  defp type_from_string("overloaded_error"), do: :overloaded
  defp type_from_string(_), do: :unknown

  defp sse_type_to_atom("invalid_request_error"), do: :invalid_request
  defp sse_type_to_atom("rate_limit_error"), do: :rate_limit
  defp sse_type_to_atom("api_error"), do: :api_error
  defp sse_type_to_atom("overloaded_error"), do: :overloaded
  defp sse_type_to_atom(_), do: :stream_error

  defp type_from_status(400), do: :invalid_request
  defp type_from_status(401), do: :authentication
  defp type_from_status(403), do: :permission
  defp type_from_status(404), do: :not_found
  defp type_from_status(429), do: :rate_limit
  defp type_from_status(status) when status in [500, 502, 503], do: :api_error
  defp type_from_status(529), do: :overloaded
  defp type_from_status(_), do: :unknown

  defp body_or_default("", status), do: default_message(status)
  defp body_or_default(body, _), do: body

  defp default_message(400), do: "Bad request"
  defp default_message(401), do: "Invalid API key"
  defp default_message(403), do: "Access denied"
  defp default_message(404), do: "Resource not found"
  defp default_message(429), do: "Rate limited"
  defp default_message(500), do: "Internal server error"
  defp default_message(502), do: "Bad gateway"
  defp default_message(503), do: "Service unavailable"
  defp default_message(529), do: "API is overloaded"
  defp default_message(_), do: "Unknown error"

  defp format_transport_error(%{reason: reason}), do: "Connection error: #{inspect(reason)}"
  defp format_transport_error(:timeout), do: "Request timeout"
  defp format_transport_error(:closed), do: "Connection closed"
  defp format_transport_error(reason), do: "Connection error: #{inspect(reason)}"

  defp get_header(headers, name) when is_list(headers) do
    name_lower = String.downcase(name)

    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == name_lower, do: value

      _ ->
        nil
    end)
  end

  defp get_header(_, _), do: nil

  defp parse_retry_after(headers) when is_list(headers) do
    case get_header(headers, "retry-after") do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {seconds, _} -> seconds * 1000
          :error -> nil
        end
    end
  end

  defp parse_retry_after(_), do: nil
end
