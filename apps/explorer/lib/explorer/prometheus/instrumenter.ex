defmodule Explorer.Prometheus.Instrumenter do
  @moduledoc """
  Prometheus metrics for Explorer core functionality.

  Tracks Chain.import stages, NATS publishing, and database operations.

  ## Chain.Import Metrics

  - `chain_import_duration_seconds` - Duration of import operations by runner (histogram)
  - `chain_import_records_total` - Records inserted per runner (counter)
  - `chain_import_errors_total` - Import errors per runner (counter)
  - `chain_import_stage_duration_seconds` - Duration per stage (histogram)
  - `chain_import_transaction_duration_seconds` - Duration of import transactions (histogram)
  - `block_import_stage_runner_duration_microseconds` - Legacy metric (histogram)

  ## NATS Publish Metrics

  - `nats_publish_duration_seconds` - Time to publish to NATS (histogram)
  - `nats_publish_total` - Total messages published (counter)
  - `nats_publish_errors_total` - Publish errors (counter)
  - `nats_publish_dropped_total` - Events dropped due to NATS disconnection (counter)
  - `nats_message_size_bytes` - Size of published messages (histogram)
  - `nats_publisher_connected` - NATS connection status (gauge)
  """

  use Prometheus.Metric

  # =============================================================================
  # Legacy Metric (kept for backward compatibility)
  # =============================================================================

  @histogram [
    name: :block_import_stage_runner_duration_microseconds,
    labels: [:stage, :runner, :step],
    buckets: [1000, 5000, 10000, 100_000],
    duration_unit: :microseconds,
    help: "Block import stage, runner and step in runner processing time"
  ]

  # =============================================================================
  # Chain.Import Metrics
  # =============================================================================

  @histogram [
    name: :chain_import_duration_seconds,
    labels: [:runner],
    buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60],
    help: "Duration of Chain.import operations by runner"
  ]

  @histogram [
    name: :chain_import_stage_duration_seconds,
    labels: [:stage],
    buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60],
    help: "Duration of Chain.import stages"
  ]

  @counter [
    name: :chain_import_records_total,
    labels: [:runner],
    help: "Total records imported by runner"
  ]

  @counter [
    name: :chain_import_errors_total,
    labels: [:runner, :error_type],
    help: "Total import errors by runner and error type"
  ]

  @histogram [
    name: :chain_import_transaction_duration_seconds,
    buckets: [0.1, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 240],
    help: "Duration of Chain.import database transactions"
  ]

  # =============================================================================
  # NATS Publish Metrics
  # =============================================================================

  @histogram [
    name: :nats_publish_duration_seconds,
    labels: [:topic],
    buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1],
    help: "Duration to publish message to NATS by topic"
  ]

  @counter [
    name: :nats_publish_total,
    labels: [:topic],
    help: "Total messages published to NATS by topic"
  ]

  @counter [
    name: :nats_publish_errors_total,
    labels: [:topic, :error_type],
    help: "Total NATS publish errors by topic and error type"
  ]

  @counter [
    name: :nats_publish_dropped_total,
    labels: [:topic],
    help: "Total events dropped due to NATS disconnection by topic"
  ]

  @histogram [
    name: :nats_message_size_bytes,
    labels: [:topic],
    buckets: [100, 500, 1000, 5000, 10000, 50000, 100_000, 500_000, 1_000_000, 5_000_000],
    help: "Size of messages published to NATS in bytes by topic"
  ]

  @gauge [
    name: :nats_publisher_connected,
    help: "Whether NATS publisher is connected (1) or not (0)"
  ]

  # =============================================================================
  # Cache/Counter Consolidation Metrics
  # =============================================================================

  @histogram [
    name: :cache_consolidation_duration_seconds,
    labels: [:cache_name, :consolidation_type],
    buckets: [0.001, 0.01, 0.1, 0.5, 1, 5, 10, 30, 60, 300, 600, 1800],
    help: "Duration of cache consolidation operations by cache name and type (init, incremental)"
  ]

  @counter [
    name: :cache_consolidation_total,
    labels: [:cache_name, :consolidation_type],
    help: "Total cache consolidation operations by cache name and type"
  ]

  @counter [
    name: :cache_consolidation_records_total,
    labels: [:cache_name],
    help: "Total records counted during consolidation"
  ]

  @gauge [
    name: :cache_checkpoint_block,
    labels: [:cache_name],
    help: "Current checkpoint block number for incremental counters"
  ]

  # =============================================================================
  # Database Query Metrics
  # =============================================================================

  @histogram [
    name: :db_query_duration_seconds,
    labels: [:operation, :query_type],
    buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30],
    help: "Database query duration by operation type"
  ]

  @counter [
    name: :db_query_total,
    labels: [:operation, :query_type],
    help: "Total database queries by operation type"
  ]

  @counter [
    name: :db_query_errors_total,
    labels: [:operation, :query_type, :error_type],
    help: "Database query errors by type"
  ]

  @histogram [
    name: :db_query_result_count,
    labels: [:query_type],
    buckets: [1, 10, 50, 100, 500, 1000, 5000, 10000],
    help: "Number of rows returned by queries"
  ]

  # =============================================================================
  # Search Metrics
  # =============================================================================

  @histogram [
    name: :search_query_duration_seconds,
    labels: [:search_type],
    buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
    help: "Search query duration by type"
  ]

  @counter [
    name: :search_queries_total,
    labels: [:search_type],
    help: "Total search queries by type"
  ]

  @histogram [
    name: :search_results_count,
    labels: [:search_type],
    buckets: [0, 1, 5, 10, 25, 50, 100],
    help: "Number of search results returned"
  ]

  # =============================================================================
  # Token/Balance Query Metrics
  # =============================================================================

  @histogram [
    name: :token_query_duration_seconds,
    labels: [:query_type],
    buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
    help: "Token-related query duration"
  ]

  @counter [
    name: :token_holders_cache_total,
    labels: [:result],
    help: "Token holders cache hits and misses"
  ]

  # =============================================================================
  # Legacy Function
  # =============================================================================

  def block_import_stage_runner(function, stage, runner, step) do
    {time, result} = :timer.tc(function)

    Histogram.observe([name: :block_import_stage_runner_duration_microseconds, labels: [stage, runner, step]], time)

    result
  end

  # =============================================================================
  # Chain.Import Functions
  # =============================================================================

  @doc """
  Record import duration for a specific runner.
  """
  def import_runner_duration(runner, duration_seconds) when is_atom(runner) do
    runner_name = runner_to_string(runner)
    Histogram.observe([name: :chain_import_duration_seconds, labels: [runner_name]], duration_seconds)
  end

  @doc """
  Record import stage duration.
  """
  def import_stage_duration(stage, duration_seconds) when is_atom(stage) do
    stage_name = Atom.to_string(stage)
    Histogram.observe([name: :chain_import_stage_duration_seconds, labels: [stage_name]], duration_seconds)
  end

  @doc """
  Increment records imported counter for a runner.
  """
  def import_records(runner, count) when is_atom(runner) and is_integer(count) and count > 0 do
    runner_name = runner_to_string(runner)
    Counter.inc([name: :chain_import_records_total, labels: [runner_name]], count)
  end

  def import_records(_, _), do: :ok

  @doc """
  Increment import errors counter.
  """
  def import_error(runner, error_type) when is_atom(runner) do
    runner_name = runner_to_string(runner)
    error_type_str = normalize_error_type(error_type)
    Counter.inc(name: :chain_import_errors_total, labels: [runner_name, error_type_str])
  end

  @doc """
  Record duration of entire import transaction.
  """
  def import_transaction_duration(duration_seconds) do
    Histogram.observe([name: :chain_import_transaction_duration_seconds], duration_seconds)
  end

  # =============================================================================
  # NATS Publish Functions
  # =============================================================================

  @doc """
  Record NATS publish metrics including duration and message size.
  """
  def nats_publish(topic, duration_seconds, message_size_bytes, result) when is_binary(topic) do
    Histogram.observe([name: :nats_publish_duration_seconds, labels: [topic]], duration_seconds)
    Histogram.observe([name: :nats_message_size_bytes, labels: [topic]], message_size_bytes)

    case result do
      :ok ->
        Counter.inc(name: :nats_publish_total, labels: [topic])

      {:error, reason} ->
        error_type = normalize_error_type(reason)
        Counter.inc(name: :nats_publish_errors_total, labels: [topic, error_type])
    end
  end

  @doc """
  Record NATS publisher connection status.
  """
  def nats_publisher_connected(connected) when is_boolean(connected) do
    value = if connected, do: 1, else: 0
    Gauge.set([name: :nats_publisher_connected], value)
  end

  @doc """
  Record events dropped due to NATS disconnection.
  """
  def nats_publish_dropped(topic, count) when is_binary(topic) and is_integer(count) do
    Counter.inc([name: :nats_publish_dropped_total, labels: [topic]], count)
  end

  # =============================================================================
  # Helper Functions
  # =============================================================================

  defp runner_to_string(runner) when is_atom(runner) do
    runner
    |> Atom.to_string()
    |> String.replace("Elixir.Explorer.Chain.Import.Runner.", "")
    |> String.downcase()
  end

  defp normalize_error_type(error) when is_atom(error), do: Atom.to_string(error)
  defp normalize_error_type(error) when is_binary(error), do: error
  defp normalize_error_type({:error, reason}), do: normalize_error_type(reason)
  defp normalize_error_type(_), do: "unknown"

  # =============================================================================
  # Cache/Counter Consolidation Functions
  # =============================================================================

  @doc """
  Record cache consolidation duration.
  consolidation_type: :init, :incremental
  """
  def cache_consolidation(cache_name, consolidation_type, duration_seconds)
      when is_atom(cache_name) and is_atom(consolidation_type) do
    cache_str = Atom.to_string(cache_name)
    type_str = Atom.to_string(consolidation_type)

    Histogram.observe(
      [name: :cache_consolidation_duration_seconds, labels: [cache_str, type_str]],
      duration_seconds
    )

    Counter.inc(name: :cache_consolidation_total, labels: [cache_str, type_str])
  end

  @doc """
  Record records counted during consolidation.
  """
  def cache_consolidation_records(cache_name, count) when is_atom(cache_name) and is_integer(count) do
    cache_str = Atom.to_string(cache_name)
    Counter.inc([name: :cache_consolidation_records_total, labels: [cache_str]], count)
  end

  @doc """
  Update checkpoint block gauge for a cache.
  """
  def cache_checkpoint(cache_name, block_number) when is_atom(cache_name) and is_integer(block_number) do
    cache_str = Atom.to_string(cache_name)
    Gauge.set([name: :cache_checkpoint_block, labels: [cache_str]], block_number)
  end

  # =============================================================================
  # Database Query Functions
  # =============================================================================

  @doc """
  Record database query metrics.
  operation: :all, :one, :aggregate, :insert, :update, :delete
  query_type: descriptive name like :address_lookup, :token_holders, :search, etc.
  """
  def db_query(operation, query_type, duration_seconds, result_count \\ nil)
      when is_atom(operation) and is_atom(query_type) do
    op_str = Atom.to_string(operation)
    type_str = Atom.to_string(query_type)

    Histogram.observe([name: :db_query_duration_seconds, labels: [op_str, type_str]], duration_seconds)
    Counter.inc(name: :db_query_total, labels: [op_str, type_str])

    if result_count && result_count > 0 do
      Histogram.observe([name: :db_query_result_count, labels: [type_str]], result_count)
    end
  end

  @doc """
  Record database query error.
  """
  def db_query_error(operation, query_type, error_type) when is_atom(operation) and is_atom(query_type) do
    op_str = Atom.to_string(operation)
    type_str = Atom.to_string(query_type)
    error_str = normalize_error_type(error_type)
    Counter.inc(name: :db_query_errors_total, labels: [op_str, type_str, error_str])
  end

  # =============================================================================
  # Search Functions
  # =============================================================================

  @doc """
  Record search query metrics.
  search_type: :joint, :balanced, :tokens, :contracts, :labels, :addresses, :blocks, :transactions
  """
  def search_query(search_type, duration_seconds, result_count) when is_atom(search_type) do
    type_str = Atom.to_string(search_type)

    Histogram.observe([name: :search_query_duration_seconds, labels: [type_str]], duration_seconds)
    Counter.inc(name: :search_queries_total, labels: [type_str])
    Histogram.observe([name: :search_results_count, labels: [type_str]], result_count || 0)
  end

  # =============================================================================
  # Token/Balance Query Functions
  # =============================================================================

  @doc """
  Record token-related query metrics.
  query_type: :holders_count, :holders_list, :transfers, :balance
  """
  def token_query(query_type, duration_seconds) when is_atom(query_type) do
    type_str = Atom.to_string(query_type)
    Histogram.observe([name: :token_query_duration_seconds, labels: [type_str]], duration_seconds)
  end

  @doc """
  Record token holders cache hit or miss.
  result: :hit, :miss
  """
  def token_holders_cache(result) when result in [:hit, :miss] do
    result_str = Atom.to_string(result)
    Counter.inc(name: :token_holders_cache_total, labels: [result_str])
  end

  # =============================================================================
  # CSV Export Metrics
  # =============================================================================

  @histogram [
    name: :csv_export_duration_seconds,
    labels: [:export_type],
    buckets: [0.1, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300],
    help: "Duration of CSV export operations by type"
  ]

  @counter [
    name: :csv_exports_total,
    labels: [:export_type],
    help: "Total CSV exports by type"
  ]

  @histogram [
    name: :csv_export_rows,
    labels: [:export_type],
    buckets: [10, 50, 100, 500, 1000, 5000, 10000],
    help: "Number of rows exported in CSV exports"
  ]

  @doc """
  Record CSV export metrics.
  export_type: :transactions, :internal_transactions, :token_transfers, :logs
  """
  def csv_export(export_type, duration_seconds, row_count \\ nil) when is_atom(export_type) do
    type_str = Atom.to_string(export_type)

    Histogram.observe([name: :csv_export_duration_seconds, labels: [type_str]], duration_seconds)
    Counter.inc(name: :csv_exports_total, labels: [type_str])

    if row_count && row_count > 0 do
      Histogram.observe([name: :csv_export_rows, labels: [type_str]], row_count)
    end
  end

  # =============================================================================
  # Smart Contract Verification Metrics
  # =============================================================================

  @histogram [
    name: :verification_duration_seconds,
    labels: [:verification_type],
    buckets: [0.1, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300],
    help: "Duration of smart contract verification by type"
  ]

  @counter [
    name: :verification_requests_total,
    labels: [:verification_type, :status],
    help: "Total verification requests by type and status (success/failure)"
  ]

  @counter [
    name: :verification_errors_total,
    labels: [:verification_type, :error_type],
    help: "Verification errors by type"
  ]

  @histogram [
    name: :verification_microservice_duration_seconds,
    labels: [:endpoint],
    buckets: [0.1, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300],
    help: "Duration of verification microservice HTTP requests"
  ]

  @doc """
  Record smart contract verification metrics.
  verification_type: :solidity_multi_part, :solidity_standard_json, :vyper_multi_part, :vyper_standard_json
  status: :success, :failure
  """
  def verification_request(verification_type, duration_seconds, status)
      when is_atom(verification_type) and status in [:success, :failure] do
    type_str = Atom.to_string(verification_type)
    status_str = Atom.to_string(status)

    Histogram.observe([name: :verification_duration_seconds, labels: [type_str]], duration_seconds)
    Counter.inc(name: :verification_requests_total, labels: [type_str, status_str])
  end

  @doc """
  Record verification error.
  """
  def verification_error(verification_type, error_type) when is_atom(verification_type) do
    type_str = Atom.to_string(verification_type)
    error_str = normalize_error_type(error_type)
    Counter.inc(name: :verification_errors_total, labels: [type_str, error_str])
  end

  @doc """
  Record verification microservice HTTP request duration.
  endpoint: :solidity_multi_part, :solidity_standard_json, :vyper_multi_part, etc.
  """
  def verification_microservice_request(endpoint, duration_seconds) when is_atom(endpoint) do
    endpoint_str = Atom.to_string(endpoint)
    Histogram.observe([name: :verification_microservice_duration_seconds, labels: [endpoint_str]], duration_seconds)
  end

  # =============================================================================
  # Smart Contract Call Metrics (eth_call)
  # =============================================================================

  @histogram [
    name: :contract_call_duration_seconds,
    labels: [:call_type],
    buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
    help: "Duration of smart contract calls (eth_call)"
  ]

  @counter [
    name: :contract_call_total,
    labels: [:call_type, :status],
    help: "Total smart contract calls by type and status"
  ]

  @counter [
    name: :contract_call_errors_total,
    labels: [:call_type, :error_type],
    help: "Smart contract call errors by type"
  ]

  @histogram [
    name: :contract_call_batch_size,
    labels: [:call_type],
    buckets: [1, 5, 10, 25, 50, 100, 250, 500],
    help: "Number of calls in contract call batches"
  ]

  @doc """
  Record smart contract call metrics.
  call_type: :query, :token_metadata, :balance, :proxy_detection
  status: :success, :error
  """
  def contract_call(call_type, duration_seconds, status, batch_size \\ 1)
      when is_atom(call_type) and status in [:success, :error, :partial] do
    type_str = Atom.to_string(call_type)
    status_str = Atom.to_string(status)

    Histogram.observe([name: :contract_call_duration_seconds, labels: [type_str]], duration_seconds)
    Counter.inc(name: :contract_call_total, labels: [type_str, status_str])

    if batch_size > 1 do
      Histogram.observe([name: :contract_call_batch_size, labels: [type_str]], batch_size)
    end
  end

  @doc """
  Record contract call error.
  """
  def contract_call_error(call_type, error_type) when is_atom(call_type) do
    type_str = Atom.to_string(call_type)
    error_str = normalize_error_type(error_type)
    Counter.inc(name: :contract_call_errors_total, labels: [type_str, error_str])
  end

  # =============================================================================
  # External API Metrics
  # =============================================================================

  @histogram [
    name: :external_api_request_duration_seconds,
    labels: [:api],
    buckets: [0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30],
    help: "Duration of external API requests (Auth0, reCAPTCHA, AirTable, etc.)"
  ]

  @counter [
    name: :external_api_requests_total,
    labels: [:api, :status],
    help: "Total external API requests by API and status"
  ]

  @counter [
    name: :external_api_errors_total,
    labels: [:api, :error_type],
    help: "External API errors by API and error type"
  ]

  @counter [
    name: :external_api_cache_total,
    labels: [:api, :result],
    help: "External API cache hits and misses"
  ]

  @doc """
  Record external API request metrics.
  api: :auth0, :recaptcha, :airtable, :eth_bytecode_db, :ipfs
  status: :success, :error
  """
  def external_api_request(api, duration_seconds, status) when is_atom(api) and status in [:success, :error] do
    api_str = Atom.to_string(api)
    status_str = Atom.to_string(status)

    Histogram.observe([name: :external_api_request_duration_seconds, labels: [api_str]], duration_seconds)
    Counter.inc(name: :external_api_requests_total, labels: [api_str, status_str])
  end

  @doc """
  Record external API error.
  """
  def external_api_error(api, error_type) when is_atom(api) do
    api_str = Atom.to_string(api)
    error_str = normalize_error_type(error_type)
    Counter.inc(name: :external_api_errors_total, labels: [api_str, error_str])
  end

  @doc """
  Record external API cache hit or miss.
  api: :auth0_m2m, etc.
  result: :hit, :miss
  """
  def external_api_cache(api, result) when is_atom(api) and result in [:hit, :miss] do
    api_str = Atom.to_string(api)
    result_str = Atom.to_string(result)
    Counter.inc(name: :external_api_cache_total, labels: [api_str, result_str])
  end
end
