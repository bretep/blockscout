defmodule BlockScoutWeb.Plugs.GraphQLMetrics do
  @moduledoc """
  Metrics recording for GraphQL requests.

  Records:
  - Query duration by operation name
  - Total queries count
  - Errors by operation and type

  Used as Absinthe.Plug's before_send callback.
  """

  alias BlockScoutWeb.Prometheus.ApiInstrumenter

  @doc """
  Absinthe before_send callback. Records GraphQL metrics before sending response.

  This is called by Absinthe.Plug with (conn, blueprint) and must return conn.
  The callback is used in Enum.reduce so only the conn should be returned.
  """
  def record_graphql_metrics(conn, blueprint) do
    operation_name = get_operation_name(conn, blueprint)
    duration = get_request_duration(conn)

    record_metrics(operation_name, duration, blueprint)

    conn
  end

  defp get_request_duration(conn) do
    # Try to get the start time from the conn's private storage
    # This is set by ApiMetrics plug
    case conn.private[:request_start_time] do
      nil ->
        # Fallback - estimate 0 if we don't have start time
        0.0

      start_time ->
        (System.monotonic_time(:microsecond) - start_time) / 1_000_000
    end
  end

  defp get_operation_name(conn, _result) do
    case conn.body_params do
      %{"operationName" => name} when is_binary(name) and name != "" ->
        name

      %{"query" => query} when is_binary(query) ->
        extract_operation_from_query(query)

      _ ->
        "unknown"
    end
  end

  defp extract_operation_from_query(query) do
    # Simple regex to extract operation name from query
    # Matches: query OperationName { ... } or mutation OperationName { ... }
    case Regex.run(~r/(?:query|mutation|subscription)\s+(\w+)/, query) do
      [_, name] -> name
      _ -> extract_field_name(query)
    end
  end

  defp extract_field_name(query) do
    # If no operation name, try to get the first field name
    # Matches: { fieldName or query { fieldName
    case Regex.run(~r/\{\s*(\w+)/, query) do
      [_, field] -> field
      _ -> "unknown"
    end
  end

  defp record_metrics(operation_name, duration_seconds, result) do
    if Code.ensure_loaded?(ApiInstrumenter) do
      try do
        ApiInstrumenter.graphql_query(operation_name, duration_seconds)

        # Check for errors in the result
        case result do
          %{errors: errors} when is_list(errors) and length(errors) > 0 ->
            Enum.each(errors, fn error ->
              error_type = get_error_type(error)
              ApiInstrumenter.graphql_error(operation_name, error_type)
            end)

          _ ->
            :ok
        end
      rescue
        _ -> :ok
      end
    end
  end

  defp get_error_type(%{message: message}) when is_binary(message) do
    message_lower = String.downcase(message)

    cond do
      String.contains?(message_lower, "not found") -> "not_found"
      String.contains?(message_lower, "invalid") -> "invalid_input"
      String.contains?(message_lower, "timeout") -> "timeout"
      String.contains?(message_lower, "unauthorized") -> "unauthorized"
      String.contains?(message_lower, "forbidden") -> "forbidden"
      String.contains?(message_lower, "complexity") -> "complexity_exceeded"
      true -> "unknown"
    end
  end

  defp get_error_type(_), do: "unknown"
end
