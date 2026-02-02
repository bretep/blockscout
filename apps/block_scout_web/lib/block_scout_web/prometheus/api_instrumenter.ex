defmodule BlockScoutWeb.Prometheus.ApiInstrumenter do
  @moduledoc """
  Prometheus metrics for API requests and SSE subscriptions.

  ## API Request Metrics

  - `api_requests_total` - Total API requests by application, endpoint, method, status
  - `api_request_duration_seconds` - Request duration histogram
  - `api_requests_active` - Currently active requests (gauge)

  ## SSE Subscription Metrics

  - `sse_subscribers_active` - Active subscribers by endpoint and entity type
  - `sse_subscriber_entity_active` - Active subscribers watching specific entities
  - `sse_event_lag_seconds` - Time from event creation to delivery
  """

  use Prometheus.Metric

  # =============================================================================
  # API Request Metrics
  # =============================================================================

  @counter [
    name: :api_requests_total,
    labels: [:application, :endpoint, :method, :status],
    help: "Total API requests by application, endpoint, method, and status class"
  ]

  @histogram [
    name: :api_request_duration_seconds,
    labels: [:application, :endpoint],
    buckets: [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
    help: "API request duration in seconds"
  ]

  @gauge [
    name: :api_requests_active,
    labels: [:endpoint],
    help: "Currently active API requests by endpoint"
  ]

  # =============================================================================
  # SSE Subscription Metrics
  # =============================================================================

  @gauge [
    name: :sse_subscribers_by_type,
    labels: [:endpoint, :entity_type],
    help: "Active SSE subscribers by endpoint and entity type (address, token, transaction, global)"
  ]

  @counter [
    name: :sse_subscriptions_total,
    labels: [:endpoint, :entity_type],
    help: "Total SSE subscriptions opened by endpoint and entity type"
  ]

  @histogram [
    name: :sse_event_lag_seconds,
    labels: [:event_type],
    buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
    help: "Time from event creation to SSE delivery in seconds"
  ]

  @histogram [
    name: :sse_nats_lag_seconds,
    labels: [:topic],
    buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1],
    help: "Time from NATS publish to receive in seconds"
  ]

  # =============================================================================
  # Top Entities Tracking
  # =============================================================================

  @counter [
    name: :sse_entity_subscriptions_total,
    labels: [:entity_type],
    help: "Total subscriptions by entity type (for identifying popular entities)"
  ]

  # =============================================================================
  # Rate Limit Metrics
  # =============================================================================

  @counter [
    name: :rate_limit_checks_total,
    labels: [:limit_type, :result],
    help: "Rate limit checks by type and result (allowed, denied)"
  ]

  @counter [
    name: :rate_limit_denied_total,
    labels: [:limit_type],
    help: "Rate limit denials by limit type"
  ]

  # =============================================================================
  # GraphQL Metrics
  # =============================================================================

  @histogram [
    name: :graphql_query_duration_seconds,
    labels: [:operation],
    buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
    help: "GraphQL query duration by operation name"
  ]

  @counter [
    name: :graphql_queries_total,
    labels: [:operation],
    help: "Total GraphQL queries by operation"
  ]

  @counter [
    name: :graphql_errors_total,
    labels: [:operation, :error_type],
    help: "GraphQL query errors by operation and type"
  ]

  @histogram [
    name: :graphql_resolver_duration_seconds,
    labels: [:resolver],
    buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
    help: "GraphQL resolver execution duration"
  ]

  # =============================================================================
  # Setup Function
  # =============================================================================

  def setup do
    :ok
  end

  # =============================================================================
  # API Request Functions
  # =============================================================================

  @doc """
  Record that a request started (increment active requests).
  """
  def api_request_started(endpoint) when is_binary(endpoint) do
    Gauge.inc(name: :api_requests_active, labels: [endpoint])
  end

  @doc """
  Record completed request metrics.
  """
  def api_request_completed(application, endpoint, method, status_class, duration_seconds)
      when is_atom(application) and is_binary(endpoint) do
    app_str = Atom.to_string(application)

    # Decrement active requests
    Gauge.dec(name: :api_requests_active, labels: [endpoint])

    # Record request count
    Counter.inc(name: :api_requests_total, labels: [app_str, endpoint, method, status_class])

    # Record duration
    Histogram.observe([name: :api_request_duration_seconds, labels: [app_str, endpoint]], duration_seconds)
  end

  # =============================================================================
  # SSE Subscription Functions
  # =============================================================================

  @doc """
  Record that a new SSE subscription was opened.
  entity_type can be: :address, :token, :transaction, :global
  """
  def sse_subscription_opened(endpoint, entity_type) when is_binary(endpoint) or is_atom(endpoint) do
    endpoint_str = to_string(endpoint)
    type_str = to_string(entity_type)

    Gauge.inc(name: :sse_subscribers_by_type, labels: [endpoint_str, type_str])
    Counter.inc(name: :sse_subscriptions_total, labels: [endpoint_str, type_str])
    Counter.inc(name: :sse_entity_subscriptions_total, labels: [type_str])
  end

  @doc """
  Record that an SSE subscription was closed.
  """
  def sse_subscription_closed(endpoint, entity_type) when is_binary(endpoint) or is_atom(endpoint) do
    endpoint_str = to_string(endpoint)
    type_str = to_string(entity_type)

    Gauge.dec(name: :sse_subscribers_by_type, labels: [endpoint_str, type_str])
  end

  @doc """
  Record event lag time (from creation to delivery).
  """
  def sse_event_lag(event_type, lag_seconds) when is_atom(event_type) or is_binary(event_type) do
    event_str = to_string(event_type)
    Histogram.observe([name: :sse_event_lag_seconds, labels: [event_str]], lag_seconds)
  end

  @doc """
  Record NATS message lag time (from publish to receive).
  """
  def nats_message_lag(topic, lag_seconds) when is_binary(topic) do
    Histogram.observe([name: :sse_nats_lag_seconds, labels: [topic]], lag_seconds)
  end

  # =============================================================================
  # Rate Limit Functions
  # =============================================================================

  @doc """
  Record a rate limit check.
  limit_type: :static_api_key, :api_key_plan, :whitelisted_ip, :api_v2_ui_token, :api_v2_ip, :global
  result: :allowed, :denied
  """
  def rate_limit_check(limit_type, result) when is_atom(limit_type) and is_atom(result) do
    type_str = to_string(limit_type)
    result_str = to_string(result)
    Counter.inc(name: :rate_limit_checks_total, labels: [type_str, result_str])

    if result == :denied do
      Counter.inc(name: :rate_limit_denied_total, labels: [type_str])
    end
  end

  # =============================================================================
  # GraphQL Functions
  # =============================================================================

  @doc """
  Record GraphQL query metrics.
  """
  def graphql_query(operation, duration_seconds) when is_binary(operation) or is_atom(operation) do
    op_str = to_string(operation)
    Histogram.observe([name: :graphql_query_duration_seconds, labels: [op_str]], duration_seconds)
    Counter.inc(name: :graphql_queries_total, labels: [op_str])
  end

  @doc """
  Record GraphQL error.
  """
  def graphql_error(operation, error_type) when is_binary(operation) or is_atom(operation) do
    op_str = to_string(operation)
    error_str = to_string(error_type)
    Counter.inc(name: :graphql_errors_total, labels: [op_str, error_str])
  end

  @doc """
  Record GraphQL resolver duration.
  """
  def graphql_resolver(resolver, duration_seconds) when is_binary(resolver) or is_atom(resolver) do
    resolver_str = to_string(resolver)
    Histogram.observe([name: :graphql_resolver_duration_seconds, labels: [resolver_str]], duration_seconds)
  end
end
