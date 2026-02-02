defmodule BlockScoutWeb.Prometheus.SSEInstrumenter do
  @moduledoc """
  Prometheus metrics for SSE (Server-Sent Events) and NATS subscriber.

  ## SSE Connection Metrics

  - `sse_connections_active` - Currently active SSE connections (gauge)
  - `sse_connections_total` - Total SSE connections opened (counter)
  - `sse_events_sent_total` - Total events sent to SSE clients (counter)
  - `sse_disconnections_total` - Total SSE disconnections (counter)
  - `sse_connection_duration_seconds` - Duration of SSE connections (histogram)

  ## NATS Subscriber Metrics

  - `nats_subscribe_events_received_total` - Total events received from NATS (counter)
  - `nats_subscriber_connected` - NATS subscriber connection status (gauge)
  - `nats_cache_operations_total` - Cache operations (counter)
  - `nats_cache_size` - Current cache size (gauge)
  """

  use Prometheus.Metric

  # =============================================================================
  # SSE Connection Metrics
  # =============================================================================

  @gauge [
    name: :sse_connections_active,
    labels: [:endpoint],
    help: "Currently active SSE connections by endpoint"
  ]

  @counter [
    name: :sse_connections_total,
    labels: [:endpoint],
    help: "Total SSE connections opened by endpoint"
  ]

  @counter [
    name: :sse_events_sent_total,
    labels: [:endpoint, :event_type],
    help: "Total events sent to SSE clients by endpoint and event type"
  ]

  @counter [
    name: :sse_disconnections_total,
    labels: [:endpoint, :reason],
    help: "Total SSE disconnections by endpoint and reason"
  ]

  @histogram [
    name: :sse_connection_duration_seconds,
    labels: [:endpoint],
    buckets: [1, 5, 10, 30, 60, 120, 300, 600, 1800, 3600],
    help: "Duration of SSE connections in seconds by endpoint"
  ]

  # =============================================================================
  # NATS Subscriber Metrics
  # =============================================================================

  @counter [
    name: :nats_subscribe_events_received_total,
    labels: [:topic],
    help: "Total events received from NATS subscription by topic"
  ]

  @gauge [
    name: :nats_subscriber_connected,
    help: "Whether NATS subscriber is connected (1) or not (0)"
  ]

  @counter [
    name: :nats_cache_operations_total,
    labels: [:operation, :cache_type],
    help: "Total cache operations by operation type and cache"
  ]

  @gauge [
    name: :nats_cache_size,
    labels: [:cache_type],
    help: "Current size of NATS subscriber cache by type"
  ]

  # =============================================================================
  # Setup function (called from Application)
  # =============================================================================

  def setup do
    # Metrics are declared via module attributes, but we need this
    # function to be called to ensure they're registered
    :ok
  end

  # =============================================================================
  # SSE Connection Functions
  # =============================================================================

  @doc """
  Record that an SSE connection was opened.
  """
  def sse_connection_opened(endpoint) when is_binary(endpoint) or is_atom(endpoint) do
    endpoint_str = to_string(endpoint)
    Counter.inc(name: :sse_connections_total, labels: [endpoint_str])
    Gauge.inc(name: :sse_connections_active, labels: [endpoint_str])
  end

  @doc """
  Record that an SSE connection was closed.
  """
  def sse_connection_closed(endpoint, reason \\ :normal) when is_binary(endpoint) or is_atom(endpoint) do
    endpoint_str = to_string(endpoint)
    reason_str = to_string(reason)
    Gauge.dec(name: :sse_connections_active, labels: [endpoint_str])
    Counter.inc(name: :sse_disconnections_total, labels: [endpoint_str, reason_str])
  end

  @doc """
  Record SSE connection duration when connection ends.
  """
  def sse_connection_duration(endpoint, duration_seconds) when is_binary(endpoint) or is_atom(endpoint) do
    endpoint_str = to_string(endpoint)
    Histogram.observe([name: :sse_connection_duration_seconds, labels: [endpoint_str]], duration_seconds)
  end

  @doc """
  Record that an event was sent to SSE clients.
  """
  def sse_event_sent(endpoint, event_type) when (is_binary(endpoint) or is_atom(endpoint)) and (is_binary(event_type) or is_atom(event_type)) do
    endpoint_str = to_string(endpoint)
    event_type_str = to_string(event_type)
    Counter.inc(name: :sse_events_sent_total, labels: [endpoint_str, event_type_str])
  end

  # =============================================================================
  # NATS Subscriber Functions
  # =============================================================================

  @doc """
  Record that an event was received from NATS.
  """
  def nats_event_received(topic) when is_binary(topic) or is_atom(topic) do
    topic_str = to_string(topic)
    Counter.inc(name: :nats_subscribe_events_received_total, labels: [topic_str])
  end

  @doc """
  Record NATS subscriber connection status.
  """
  def nats_subscriber_connected(connected) when is_boolean(connected) do
    value = if connected, do: 1, else: 0
    Gauge.set([name: :nats_subscriber_connected], value)
  end

  @doc """
  Record a cache operation.
  """
  def nats_cache_operation(operation, cache_type) when is_atom(operation) and is_atom(cache_type) do
    Counter.inc(name: :nats_cache_operations_total, labels: [to_string(operation), to_string(cache_type)])
  end

  @doc """
  Update cache size gauge.
  """
  def nats_cache_size(cache_type, size) when is_atom(cache_type) and is_integer(size) do
    Gauge.set([name: :nats_cache_size, labels: [to_string(cache_type)]], size)
  end
end
