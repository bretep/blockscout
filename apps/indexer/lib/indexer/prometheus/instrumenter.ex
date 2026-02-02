defmodule Indexer.Prometheus.Instrumenter do
  @moduledoc """
  Blocks fetch and import metrics for `Prometheus`.
  """

  use Prometheus.Metric

  @histogram [
    name: :block_full_processing_duration_microseconds,
    labels: [:fetcher],
    buckets: [1000, 5000, 10000, 100_000],
    duration_unit: :microseconds,
    help: "Block whole processing time including fetch and import"
  ]

  @histogram [
    name: :block_import_duration_microseconds,
    labels: [:fetcher],
    buckets: [1000, 5000, 10000, 100_000],
    duration_unit: :microseconds,
    help: "Block import time"
  ]

  @histogram [
    name: :block_batch_fetch_request_duration_microseconds,
    labels: [:fetcher],
    buckets: [1000, 5000, 10000, 100_000],
    duration_unit: :microseconds,
    help: "Block fetch batch request processing time"
  ]

  @gauge [name: :missing_block_count, help: "Number of missing blocks in the database"]

  @gauge [name: :delay_from_last_node_block, help: "Delay from the last block on the node in seconds"]

  @counter [name: :import_errors_count, help: "Number of database import errors"]

  # Realtime fetcher metrics
  @counter [
    name: :realtime_block_fetch_success_total,
    help: "Total number of blocks successfully fetched by realtime indexer"
  ]

  @counter [
    name: :realtime_block_fetch_failure_total,
    labels: [:reason, :step],
    help: "Total number of block fetch failures by realtime indexer (step: blocks, receipts, balances, import)"
  ]

  @counter [
    name: :realtime_blocks_detected_total,
    help: "Total number of new blocks detected by realtime indexer"
  ]

  @counter [
    name: :realtime_blocks_gap_total,
    help: "Total number of gap blocks spawned by realtime indexer (blocks between previous and current)"
  ]

  @gauge [
    name: :realtime_last_block_number,
    help: "Last block number processed by realtime indexer"
  ]

  @gauge [
    name: :realtime_previous_block_number,
    help: "Previous block number tracked by realtime indexer"
  ]

  @histogram [
    name: :realtime_block_fetch_duration_seconds,
    buckets: [0.1, 0.5, 1, 2, 5, 10, 30, 60],
    help: "Duration of individual block fetch and import by realtime indexer"
  ]

  @counter [
    name: :realtime_reorg_detected_total,
    help: "Total number of reorgs detected by realtime indexer"
  ]

  # Catchup fetcher metrics
  @counter [
    name: :catchup_block_fetch_success_total,
    help: "Total number of blocks successfully fetched by catchup indexer"
  ]

  @counter [
    name: :catchup_block_fetch_failure_total,
    labels: [:reason],
    help: "Total number of block fetch failures by catchup indexer"
  ]

  @counter [
    name: :catchup_batch_processed_total,
    help: "Total number of batches processed by catchup indexer"
  ]

  @gauge [
    name: :catchup_blocks_remaining,
    help: "Number of blocks remaining for catchup indexer to process"
  ]

  @histogram [
    name: :catchup_batch_duration_seconds,
    buckets: [1, 5, 10, 30, 60, 120, 300],
    help: "Duration of catchup batch processing"
  ]

  # Missing ranges metrics
  @gauge [
    name: :missing_ranges_count,
    help: "Number of missing block ranges in the database"
  ]

  @gauge [
    name: :missing_ranges_min_block,
    help: "Minimum block number in missing ranges"
  ]

  @gauge [
    name: :missing_ranges_max_block,
    help: "Maximum block number in missing ranges"
  ]

  # =============================================================================
  # JSON-RPC Metrics
  # =============================================================================

  @histogram [
    name: :jsonrpc_request_duration_seconds,
    labels: [:method],
    buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120],
    help: "Duration of JSON-RPC requests by method"
  ]

  @counter [
    name: :jsonrpc_requests_total,
    labels: [:method, :status],
    help: "Total JSON-RPC requests by method and status (success/error)"
  ]

  @counter [
    name: :jsonrpc_errors_total,
    labels: [:method, :error_type],
    help: "Total JSON-RPC errors by method and error type"
  ]

  @histogram [
    name: :jsonrpc_response_size_bytes,
    labels: [:method],
    buckets: [100, 1000, 10000, 100_000, 1_000_000, 10_000_000, 100_000_000],
    help: "Size of JSON-RPC responses in bytes by method"
  ]

  @counter [
    name: :jsonrpc_batch_requests_total,
    labels: [:method],
    help: "Total JSON-RPC batch requests by method"
  ]

  @histogram [
    name: :jsonrpc_batch_size,
    labels: [:method],
    buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000],
    help: "Number of requests in JSON-RPC batches by method"
  ]

  # =============================================================================
  # Fetcher Metrics
  # =============================================================================

  @histogram [
    name: :fetcher_run_duration_seconds,
    labels: [:fetcher],
    buckets: [0.1, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300],
    help: "Duration of fetcher runs by fetcher name"
  ]

  @counter [
    name: :fetcher_items_processed_total,
    labels: [:fetcher],
    help: "Total items processed by fetcher"
  ]

  @counter [
    name: :fetcher_errors_total,
    labels: [:fetcher, :error_type],
    help: "Total fetcher errors by fetcher and error type"
  ]

  @counter [
    name: :fetcher_rpc_calls_total,
    labels: [:fetcher, :method],
    help: "Total RPC calls made by fetcher by method"
  ]

  @gauge [
    name: :fetcher_queue_size,
    labels: [:fetcher],
    help: "Current queue size for fetchers"
  ]

  @counter [
    name: :fetcher_retries_total,
    labels: [:fetcher, :reason],
    help: "Total retries by fetcher and reason (fetch_error, import_error, db_error)"
  ]

  @counter [
    name: :fetcher_blocks_retried_total,
    labels: [:fetcher],
    help: "Total blocks/items retried by fetcher"
  ]

  # Existing functions
  def block_full_process(time, fetcher) do
    Histogram.observe([name: :block_full_processing_duration_microseconds, labels: [fetcher]], time)
  end

  def block_import(time, fetcher) do
    Histogram.observe([name: :block_import_duration_microseconds, labels: [fetcher]], time)
  end

  def block_batch_fetch(time, fetcher) do
    Histogram.observe([name: :block_batch_fetch_request_duration_microseconds, labels: [fetcher]], time)
  end

  def missing_blocks(missing_block_count) do
    Gauge.set([name: :missing_block_count], missing_block_count)
  end

  def node_delay(delay) do
    Gauge.set([name: :delay_from_last_node_block], delay)
  end

  def import_errors(error_count \\ 1) do
    Counter.inc([name: :import_errors_count], error_count)
  end

  # Realtime fetcher functions
  def realtime_block_success do
    Counter.inc(name: :realtime_block_fetch_success_total)
  end

  def realtime_block_failure(reason, step \\ :unknown) do
    step_str = if is_atom(step), do: Atom.to_string(step), else: to_string(step)
    Counter.inc(name: :realtime_block_fetch_failure_total, labels: [reason, step_str])
  end

  def realtime_block_detected do
    Counter.inc(name: :realtime_blocks_detected_total)
  end

  def realtime_gap_blocks(count) when count > 0 do
    Counter.inc([name: :realtime_blocks_gap_total], count)
  end

  def realtime_gap_blocks(_), do: :ok

  def realtime_last_block(number) do
    Gauge.set([name: :realtime_last_block_number], number)
  end

  def realtime_previous_block(number) do
    Gauge.set([name: :realtime_previous_block_number], number)
  end

  def realtime_fetch_duration(duration_seconds) do
    Histogram.observe([name: :realtime_block_fetch_duration_seconds], duration_seconds)
  end

  def realtime_reorg_detected do
    Counter.inc(name: :realtime_reorg_detected_total)
  end

  # Catchup fetcher functions
  def catchup_block_success(count \\ 1) do
    Counter.inc([name: :catchup_block_fetch_success_total], count)
  end

  def catchup_block_failure(reason) do
    Counter.inc(name: :catchup_block_fetch_failure_total, labels: [reason])
  end

  def catchup_batch_processed do
    Counter.inc(name: :catchup_batch_processed_total)
  end

  def catchup_blocks_remaining(count) do
    Gauge.set([name: :catchup_blocks_remaining], count)
  end

  def catchup_batch_duration(duration_seconds) do
    Histogram.observe([name: :catchup_batch_duration_seconds], duration_seconds)
  end

  # Missing ranges functions
  def missing_ranges_stats(count, min_block, max_block) do
    Gauge.set([name: :missing_ranges_count], count)

    if min_block do
      Gauge.set([name: :missing_ranges_min_block], min_block)
    end

    if max_block do
      Gauge.set([name: :missing_ranges_max_block], max_block)
    end
  end

  # =============================================================================
  # JSON-RPC Functions
  # =============================================================================

  @doc """
  Record JSON-RPC request metrics.
  """
  def jsonrpc_request(method, duration_seconds, status, response_size_bytes \\ nil) do
    method_str = normalize_method(method)
    status_str = if status == :ok, do: "success", else: "error"

    Histogram.observe([name: :jsonrpc_request_duration_seconds, labels: [method_str]], duration_seconds)
    Counter.inc(name: :jsonrpc_requests_total, labels: [method_str, status_str])

    if response_size_bytes && response_size_bytes > 0 do
      Histogram.observe([name: :jsonrpc_response_size_bytes, labels: [method_str]], response_size_bytes)
    end
  end

  @doc """
  Record JSON-RPC error.
  """
  def jsonrpc_error(method, error_type) do
    method_str = normalize_method(method)
    error_str = normalize_error_type(error_type)
    Counter.inc(name: :jsonrpc_errors_total, labels: [method_str, error_str])
  end

  @doc """
  Record JSON-RPC batch request.
  """
  def jsonrpc_batch_request(method, batch_size) when is_integer(batch_size) and batch_size > 0 do
    method_str = normalize_method(method)
    Counter.inc(name: :jsonrpc_batch_requests_total, labels: [method_str])
    Histogram.observe([name: :jsonrpc_batch_size, labels: [method_str]], batch_size)
  end

  def jsonrpc_batch_request(_, _), do: :ok

  # =============================================================================
  # Fetcher Functions
  # =============================================================================

  @doc """
  Record fetcher run duration.
  """
  def fetcher_run_duration(fetcher, duration_seconds) when is_atom(fetcher) or is_binary(fetcher) do
    fetcher_str = normalize_fetcher(fetcher)
    Histogram.observe([name: :fetcher_run_duration_seconds, labels: [fetcher_str]], duration_seconds)
  end

  @doc """
  Record items processed by fetcher.
  """
  def fetcher_items_processed(fetcher, count) when is_integer(count) and count > 0 do
    fetcher_str = normalize_fetcher(fetcher)
    Counter.inc([name: :fetcher_items_processed_total, labels: [fetcher_str]], count)
  end

  def fetcher_items_processed(_, _), do: :ok

  @doc """
  Record fetcher error.
  """
  def fetcher_error(fetcher, error_type) do
    fetcher_str = normalize_fetcher(fetcher)
    error_str = normalize_error_type(error_type)
    Counter.inc(name: :fetcher_errors_total, labels: [fetcher_str, error_str])
  end

  @doc """
  Record RPC call made by fetcher.
  """
  def fetcher_rpc_call(fetcher, method) do
    fetcher_str = normalize_fetcher(fetcher)
    method_str = normalize_method(method)
    Counter.inc(name: :fetcher_rpc_calls_total, labels: [fetcher_str, method_str])
  end

  @doc """
  Update fetcher queue size.
  """
  def fetcher_queue_size(fetcher, size) when is_integer(size) do
    fetcher_str = normalize_fetcher(fetcher)
    Gauge.set([name: :fetcher_queue_size, labels: [fetcher_str]], size)
  end

  @doc """
  Record a retry event for a fetcher.
  reason: :fetch_error, :import_error, :db_error, :timeout
  """
  def fetcher_retry(fetcher, reason, block_count \\ 1) when is_atom(reason) do
    fetcher_str = normalize_fetcher(fetcher)
    reason_str = Atom.to_string(reason)
    Counter.inc(name: :fetcher_retries_total, labels: [fetcher_str, reason_str])
    Counter.inc([name: :fetcher_blocks_retried_total, labels: [fetcher_str]], block_count)
  end

  # =============================================================================
  # On-Demand Fetcher Metrics
  # =============================================================================

  @histogram [
    name: :on_demand_fetch_duration_seconds,
    labels: [:fetch_type],
    buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30],
    help: "Duration of on-demand fetch operations by type"
  ]

  @counter [
    name: :on_demand_fetch_total,
    labels: [:fetch_type, :status],
    help: "Total on-demand fetches by type and status (success/error/skipped)"
  ]

  @counter [
    name: :on_demand_fetch_errors_total,
    labels: [:fetch_type, :error_type],
    help: "On-demand fetch errors by type"
  ]

  @histogram [
    name: :on_demand_staleness_blocks,
    labels: [:fetch_type],
    buckets: [10, 50, 100, 500, 1000, 5000, 10000],
    help: "How many blocks stale the data was before on-demand fetch"
  ]

  @doc """
  Record on-demand fetch metrics.
  fetch_type: :coin_balance, :token_balance, :first_trace
  status: :success, :error, :skipped
  """
  def on_demand_fetch(fetch_type, duration_seconds, status, staleness_blocks \\ nil)
      when is_atom(fetch_type) and status in [:success, :error, :skipped] do
    type_str = Atom.to_string(fetch_type)
    status_str = Atom.to_string(status)

    Histogram.observe([name: :on_demand_fetch_duration_seconds, labels: [type_str]], duration_seconds)
    Counter.inc(name: :on_demand_fetch_total, labels: [type_str, status_str])

    if staleness_blocks && staleness_blocks > 0 do
      Histogram.observe([name: :on_demand_staleness_blocks, labels: [type_str]], staleness_blocks)
    end
  end

  @doc """
  Record on-demand fetch error.
  """
  def on_demand_fetch_error(fetch_type, error_type) when is_atom(fetch_type) do
    type_str = Atom.to_string(fetch_type)
    error_str = normalize_error_type(error_type)
    Counter.inc(name: :on_demand_fetch_errors_total, labels: [type_str, error_str])
  end

  # =============================================================================
  # Token Metadata Fetch Metrics
  # =============================================================================

  @histogram [
    name: :token_metadata_fetch_duration_seconds,
    labels: [:source],
    buckets: [0.1, 0.5, 1, 2.5, 5, 10, 30, 60],
    help: "Duration of token metadata fetch by source (http, ipfs, data_uri)"
  ]

  @counter [
    name: :token_metadata_fetch_total,
    labels: [:source, :status],
    help: "Total token metadata fetches by source and status"
  ]

  @counter [
    name: :token_metadata_fetch_errors_total,
    labels: [:source, :error_type],
    help: "Token metadata fetch errors by source and error type"
  ]

  @doc """
  Record token metadata fetch metrics.
  source: :http, :ipfs, :data_uri
  status: :success, :error
  """
  def token_metadata_fetch(source, duration_seconds, status)
      when is_atom(source) and status in [:success, :error] do
    source_str = Atom.to_string(source)
    status_str = Atom.to_string(status)

    Histogram.observe([name: :token_metadata_fetch_duration_seconds, labels: [source_str]], duration_seconds)
    Counter.inc(name: :token_metadata_fetch_total, labels: [source_str, status_str])
  end

  @doc """
  Record token metadata fetch error.
  """
  def token_metadata_fetch_error(source, error_type) when is_atom(source) do
    source_str = Atom.to_string(source)
    error_str = normalize_error_type(error_type)
    Counter.inc(name: :token_metadata_fetch_errors_total, labels: [source_str, error_str])
  end

  # =============================================================================
  # Memory Monitor Metrics
  # =============================================================================

  @gauge [
    name: :indexer_memory_usage_bytes,
    help: "Current memory usage of the indexer in bytes"
  ]

  @gauge [
    name: :indexer_memory_limit_bytes,
    help: "Configured memory limit for the indexer in bytes"
  ]

  @counter [
    name: :indexer_memory_shrink_total,
    help: "Total times memory shrinking was triggered"
  ]

  @doc """
  Record current memory usage.
  """
  def memory_usage(usage_bytes, limit_bytes) when is_integer(usage_bytes) and is_integer(limit_bytes) do
    Gauge.set([name: :indexer_memory_usage_bytes], usage_bytes)
    Gauge.set([name: :indexer_memory_limit_bytes], limit_bytes)
  end

  @doc """
  Record memory shrink event.
  """
  def memory_shrink do
    Counter.inc(name: :indexer_memory_shrink_total)
  end

  # =============================================================================
  # Helper Functions
  # =============================================================================

  defp normalize_method(method) when is_binary(method), do: method
  defp normalize_method(method) when is_atom(method), do: Atom.to_string(method)
  defp normalize_method(_), do: "unknown"

  defp normalize_fetcher(fetcher) when is_binary(fetcher), do: fetcher
  defp normalize_fetcher(fetcher) when is_atom(fetcher) do
    fetcher
    |> Atom.to_string()
    |> String.replace("Elixir.Indexer.Fetcher.", "")
    |> String.downcase()
  end
  defp normalize_fetcher(_), do: "unknown"

  defp normalize_error_type(error) when is_atom(error), do: Atom.to_string(error)
  defp normalize_error_type(error) when is_binary(error), do: error
  defp normalize_error_type({:error, reason}), do: normalize_error_type(reason)
  defp normalize_error_type(%{message: msg}) when is_binary(msg), do: msg
  defp normalize_error_type(_), do: "unknown"
end
