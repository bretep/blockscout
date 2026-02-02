defmodule BlockScoutWeb.SSE.EventController do
  @moduledoc """
  Server-Sent Events (SSE) controller for real-time blockchain updates.

  Provides both generic event streaming and entity-specific endpoints that
  mirror the Phoenix channel structure expected by the frontend. This replaces
  both WebSocket channels and polling for a unified SSE approach.

  ## Generic Endpoints

  - `GET /api/v2/sse/events` - All events
  - `GET /api/v2/sse/events?topics=blocks,transactions` - Specific event types
  - `GET /api/v2/sse/events?address=0x123...` - Events filtered by address
  - `GET /api/v2/sse/events?token=0x456...` - Events filtered by token

  ## Entity-Specific Endpoints (Phoenix Channel Compatible)

  - `GET /api/v2/sse/addresses/:address_hash` - Address-specific events
    Events: transaction, pending_transaction, token_transfer, coin_balance,
            token_balance, internal_transaction, changed_bytecode, verification_result

  - `GET /api/v2/sse/transactions/:tx_hash` - Transaction-specific events
    Events: pending (tx in mempool), collated (tx included in block), raw_trace (traces available)
    Useful for wallets to track a pending transaction until confirmation.

  - `GET /api/v2/sse/tokens/:token_address` - Token-specific events
    Events: token_transfer, total_supply

  - `GET /api/v2/sse/blocks` - Block events
    Events: new_block

  ## Global Event Streams (Replaces Polling)

  - `GET /api/v2/sse/pending-transactions` - Pending mempool transactions
    Events: pending_transaction
    Rate limited via SSE_PENDING_RATE_LIMIT (default: 10/sec, set 0 to disable)
    For tracking a specific pending tx, use `/api/v2/sse/transactions/:tx_hash` instead.

  - `GET /api/v2/sse/new-transactions` - New validated transactions
    Events: transaction

  - `GET /api/v2/sse/stats` - Stats updates (replaces polling)
    Events: exchange_rate, transaction_stats

  ## Event Format

  Events are sent as JSON matching Phoenix channel format:

      event: new_block
      data: {"number": 12345, "hash": "0x...", ...}

  ## Example Usage (JavaScript)

      // Watch specific address (like Phoenix addresses:{hash} channel)
      const es = new EventSource('/api/v2/sse/addresses/0x123...');
      es.addEventListener('transaction', (e) => console.log('New tx:', JSON.parse(e.data)));
      es.addEventListener('pending_transaction', (e) => console.log('Pending:', JSON.parse(e.data)));
      es.addEventListener('verification_result', (e) => console.log('Verified:', JSON.parse(e.data)));

      // Watch specific transaction (from pending through confirmation)
      // Ideal for wallets tracking their submitted transactions
      const es = new EventSource('/api/v2/sse/transactions/0xabc...');
      es.addEventListener('pending', (e) => console.log('In mempool:', JSON.parse(e.data)));
      es.addEventListener('collated', (e) => console.log('Confirmed!', JSON.parse(e.data)));
      es.addEventListener('raw_trace', (e) => console.log('Traces ready:', JSON.parse(e.data)));

      // Watch new blocks (replaces polling)
      const es = new EventSource('/api/v2/sse/blocks');
      es.addEventListener('new_block', (e) => console.log('Block:', JSON.parse(e.data)));

      // On reconnect, pass last known block to avoid receiving old blocks again
      let lastBlockNumber = 0;
      es.addEventListener('new_block', (e) => {
        const block = JSON.parse(e.data);
        lastBlockNumber = Math.max(lastBlockNumber, block.number);
      });
      es.onerror = () => {
        // Reconnect with last known block
        const reconnectUrl = `/api/v2/sse/blocks?last_block_number=${lastBlockNumber}`;
        new EventSource(reconnectUrl);
      };

      // Watch stats updates (replaces polling every 2 minutes)
      const es = new EventSource('/api/v2/sse/stats');
      es.addEventListener('exchange_rate', (e) => console.log('Price:', JSON.parse(e.data)));
      es.addEventListener('transaction_stats', (e) => console.log('Stats:', JSON.parse(e.data)));
  """

  use BlockScoutWeb, :controller

  require Logger

  alias BlockScoutWeb.Nats.Subscriber
  alias BlockScoutWeb.Prometheus.{ApiInstrumenter, SSEInstrumenter}
  alias BlockScoutWeb.SSE.ConnectionTracker

  # SSE cache limits - configurable via environment variables
  defp sse_cache_limit_transactions do
    case System.get_env("SSE_CACHE_LIMIT_TRANSACTIONS") do
      nil -> 100
      val -> String.to_integer(val)
    end
  end

  defp sse_cache_limit_pending_transactions do
    case System.get_env("SSE_CACHE_LIMIT_PENDING_TRANSACTIONS") do
      nil -> 100
      val -> String.to_integer(val)
    end
  end

  defp sse_cache_limit_blocks do
    case System.get_env("SSE_CACHE_LIMIT_BLOCKS") do
      nil -> 50
      val -> String.to_integer(val)
    end
  end

  # Rate limit for pending transactions (per second) - prevents overwhelming clients
  # Set to 0 to disable the global pending stream entirely (recommended for busy chains)
  # Default: 10 pending txs per second max
  defp sse_pending_rate_limit do
    case System.get_env("SSE_PENDING_RATE_LIMIT") do
      nil -> 10
      val -> String.to_integer(val)
    end
  end

  # All topics supported by NATS publisher
  @valid_topics ~w(
    blocks
    pending_transactions
    transactions
    token_transfers
    addresses
    address_coin_balances
    address_token_balances
    address_current_token_balances
    block_rewards
    internal_transactions
    last_block_number
    token_total_supply
    contract_verification
    changed_bytecode
    exchange_rate
    transaction_stats
    raw_traces
  )

  def events(conn, params) do
    try do
      topics = parse_topics(params)
      filters = parse_filters(params)

      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("access-control-allow-origin", "*")
      |> send_chunked(200)
      |> subscribe_and_stream(topics, filters)
    rescue
      e ->
        Logger.error("[SSE] Error in events: #{inspect(e)}")

        conn
        |> setup_sse_headers()
        |> send_resp(500, "event: error\ndata: {\"message\": \"Internal server error\"}\n\n")
    end
  end

  # =============================================================================
  # Entity-Specific Endpoints (Phoenix Channel Compatible)
  # =============================================================================

  @doc """
  Stream events for a specific address.
  Mirrors the Phoenix `addresses:{hash}` channel.

  Events emitted:
  - transaction: New transaction involving this address
  - pending_transaction: Pending transaction involving this address
  - token_transfer: Token transfer to/from this address
  - coin_balance: Native coin balance update
  - token_balance: Token balance update
  - changed_bytecode: Contract bytecode changed (SELFDESTRUCT)
  - verification_result: Contract verification completed
  """
  def address_events(conn, %{"address_hash" => address_hash}) do
    try do
      address = normalize_address(address_hash)

      topics = [
        :pending_transactions,
        :transactions,
        :token_transfers,
        :address_coin_balances,
        :address_token_balances,
        :address_current_token_balances,
        :internal_transactions,
        :contract_verification,
        :changed_bytecode
      ]

      conn
      |> setup_sse_headers()
      |> send_chunked(200)
      |> stream_entity_events(topics, {:address, address})
    rescue
      e ->
        Logger.error("[SSE] Error in address_events: #{inspect(e)}")

        conn
        |> setup_sse_headers()
        |> send_resp(500, "event: error\ndata: {\"message\": \"Internal server error\"}\n\n")
    end
  end

  @doc """
  Stream events for a specific transaction.
  Mirrors the Phoenix `transactions:{hash}` channel.

  Useful for wallets to track a pending transaction until confirmation.

  Events emitted:
  - pending: Transaction is in the mempool (from cache or live update)
  - collated: Transaction was included in a block (confirmed)
  - raw_trace: Transaction traces are now available
  """
  def transaction_events(conn, %{"tx_hash" => tx_hash}) do
    try do
      tx = normalize_hash(tx_hash)

      conn
      |> setup_sse_headers()
      |> send_chunked(200)
      |> stream_transaction_with_pending_check(tx)
    rescue
      e ->
        Logger.error("[SSE] Error in transaction_events: #{inspect(e)}")

        conn
        |> setup_sse_headers()
        |> send_resp(500, "event: error\ndata: {\"message\": \"Internal server error\"}\n\n")
    end
  end

  # Stream transaction events with pending check
  # Subscribes to pending_transactions, transactions, and raw_traces
  # Checks pending cache on connect and emits "pending" if found
  defp stream_transaction_with_pending_check(conn, tx_hash) do
    # Subscribe to pending, confirmed transactions, and traces
    topics = [:pending_transactions, :transactions, :raw_traces]
    endpoint = "transactions"
    entity_type = :transaction
    start_time = System.monotonic_time(:second)
    entity_filter = {:transaction, tx_hash}

    # Track subscription
    record_connection_opened(endpoint)
    record_subscription_opened(endpoint, entity_type)

    # Subscribe to all topics
    Enum.each(topics, &Subscriber.subscribe/1)

    # Send initial connection message
    {:ok, conn} =
      send_sse_event(conn, "connected", %{
        entity: format_entity_filter(entity_filter),
        timestamp: DateTime.utc_now()
      })

    # Check if this transaction is in the pending cache
    # This lets wallets immediately know if their tx is pending
    conn = check_and_send_pending_tx(conn, tx_hash, endpoint)

    # Start event loop
    entity_event_loop_with_subscription_cleanup(conn, topics, entity_filter, endpoint, entity_type, start_time)
  end

  # Check pending cache for a specific transaction and send "pending" event if found
  defp check_and_send_pending_tx(conn, tx_hash, endpoint) do
    cached_pending = Subscriber.get_cached_pending_transactions()

    case Enum.find(cached_pending, fn tx ->
           matches_hash?(tx["hash"], tx_hash)
         end) do
      nil ->
        conn

      pending_tx ->
        case send_sse_event(conn, "pending", pending_tx) do
          {:ok, conn} ->
            record_event_sent(endpoint, "pending")
            conn

          {:error, _} ->
            conn
        end
    end
  end

  @doc """
  Stream events for a specific token.
  Mirrors the Phoenix `tokens:{address}` channel.

  Events emitted:
  - token_transfer: Transfer of this token
  - total_supply: Token total supply changed
  """
  def token_events(conn, %{"token_address" => token_address}) do
    try do
      token = normalize_address(token_address)

      conn
      |> setup_sse_headers()
      |> send_chunked(200)
      |> stream_entity_events([:token_transfers, :token_total_supply], {:token, token})
    rescue
      e ->
        Logger.error("[SSE] Error in token_events: #{inspect(e)}")

        conn
        |> setup_sse_headers()
        |> send_resp(500, "event: error\ndata: {\"message\": \"Internal server error\"}\n\n")
    end
  end

  @doc """
  Stream block events.
  Mirrors the Phoenix `blocks:new_block` channel.

  On connect, immediately sends the cached last block so clients have
  current data without hitting the database. Then streams live updates.

  Query parameters:
  - `last_block_number`: Optional. If provided, only sends cached blocks newer than
    this number. Useful on reconnect to avoid receiving blocks the client already has.

  Events emitted:
  - new_block: New block mined
  """
  def block_events(conn, params) do
    try do
      # Parse last_block_number for filtering on reconnect
      last_block_number = parse_last_block_number(params["last_block_number"])

      conn
      |> setup_sse_headers()
      |> send_chunked(200)
      |> stream_blocks_with_cache(last_block_number)
    rescue
      e ->
        Logger.error("[SSE] Error in block_events: #{inspect(e)}")

        conn
        |> setup_sse_headers()
        |> send_resp(500, "event: error\ndata: {\"message\": \"Internal server error\"}\n\n")
    end
  end

  # Parse last_block_number parameter (returns nil if not provided or invalid)
  defp parse_last_block_number(nil), do: nil
  defp parse_last_block_number(""), do: nil

  defp parse_last_block_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {num, ""} when num >= 0 -> num
      _ -> nil
    end
  end

  defp parse_last_block_number(_), do: nil

  defp stream_blocks_with_cache(conn, last_block_number \\ nil) do
    topics = [:blocks]
    endpoint = "blocks"
    start_time = System.monotonic_time(:second)

    # Track connection opened
    record_connection_opened(endpoint)

    # Subscribe to topics
    Enum.each(topics, &Subscriber.subscribe/1)

    # Send connection message with last_block_number acknowledgment
    {:ok, conn} =
      send_sse_event(conn, "connected", %{
        entity: format_entity_filter(:blocks),
        timestamp: DateTime.utc_now(),
        last_block_number: last_block_number
      })

    # Send cached blocks immediately for page population
    # Configurable via SSE_CACHE_LIMIT_BLOCKS env var (default: 50)
    # If last_block_number is provided (reconnect), only send blocks newer than that
    cached_blocks =
      Subscriber.get_cached_blocks()
      |> filter_blocks_by_last_number(last_block_number)
      |> Enum.take(sse_cache_limit_blocks())

    conn =
      Enum.reduce(cached_blocks, conn, fn block, acc_conn ->
        case send_sse_event(acc_conn, "new_block", block) do
          {:ok, new_conn} ->
            record_event_sent(endpoint, "new_block")
            new_conn

          {:error, _} ->
            acc_conn
        end
      end)

    # Signal that initial cache is complete
    # Include skipped count so client knows blocks were filtered
    skipped_count =
      if last_block_number do
        all_cached = Subscriber.get_cached_blocks()
        length(all_cached) - length(cached_blocks)
      else
        0
      end

    {:ok, conn} =
      send_sse_event(conn, "cache_complete", %{
        count: length(cached_blocks),
        skipped: skipped_count
      })

    # Start event loop with cleanup tracking
    entity_event_loop_with_cleanup(conn, topics, :blocks, endpoint, start_time)
  end

  # Filter cached blocks to only include those newer than last_block_number
  # Returns all blocks if last_block_number is nil (fresh connect)
  defp filter_blocks_by_last_number(blocks, nil), do: blocks

  defp filter_blocks_by_last_number(blocks, last_block_number) when is_integer(last_block_number) do
    Enum.filter(blocks, fn block ->
      # Block number can be in "number" field (from serialization)
      block_num = get_block_number(block)
      block_num != nil and block_num > last_block_number
    end)
  end

  # Extract block number from block data (handles different formats)
  defp get_block_number(%{"number" => num}) when is_integer(num), do: num
  defp get_block_number(%{"number" => num}) when is_binary(num) do
    case Integer.parse(num) do
      {n, ""} -> n
      _ -> nil
    end
  end
  defp get_block_number(%{number: num}) when is_integer(num), do: num
  defp get_block_number(_), do: nil

  @doc """
  Stream pending (mempool) transaction events.
  Mirrors the Phoenix `transactions:new_pending_transaction` channel.

  On connect, immediately sends cached pending transactions for page population.

  Events emitted:
  - pending_transaction: New pending transaction in mempool
  """
  def pending_transaction_events(conn, _params) do
    try do
      conn
      |> setup_sse_headers()
      |> send_chunked(200)
      |> stream_pending_transactions_with_cache()
    rescue
      e ->
        Logger.error("[SSE] Error in pending_transaction_events: #{inspect(e)}")

        conn
        |> setup_sse_headers()
        |> send_resp(500, "event: error\ndata: {\"message\": \"Internal server error\"}\n\n")
    end
  end

  defp stream_pending_transactions_with_cache(conn) do
    topics = [:pending_transactions]
    endpoint = "pending_transactions"
    start_time = System.monotonic_time(:second)
    rate_limit = sse_pending_rate_limit()

    record_connection_opened(endpoint)

    # Check if pending stream is disabled (rate_limit = 0)
    if rate_limit == 0 do
      {:ok, conn} =
        send_sse_event(conn, "error", %{
          message:
            "Global pending transactions stream is disabled. Use /api/v2/sse/transactions/:tx_hash to watch a specific transaction.",
          code: "stream_disabled"
        })

      cleanup_with_metrics(topics, endpoint, start_time, :disabled)
      conn
    else
      Enum.each(topics, &Subscriber.subscribe/1)

      {:ok, conn} =
        send_sse_event(conn, "connected", %{
          entity: format_entity_filter(:pending_transactions),
          rate_limit: rate_limit,
          timestamp: DateTime.utc_now()
        })

      # Send only the most recent cached pending transactions to avoid flooding
      # The full list can have thousands on busy chains
      # Configurable via SSE_CACHE_LIMIT_PENDING_TRANSACTIONS env var (default: 100)
      cached =
        Subscriber.get_cached_pending_transactions()
        |> Enum.take(sse_cache_limit_pending_transactions())

      conn =
        Enum.reduce(cached, conn, fn tx, acc_conn ->
          case send_sse_event(acc_conn, "pending_transaction", tx) do
            {:ok, new_conn} ->
              record_event_sent(endpoint, "pending_transaction")
              new_conn

            {:error, _} ->
              acc_conn
          end
        end)

      # Signal that initial cache is complete - frontend can start counting new txs from here
      {:ok, conn} = send_sse_event(conn, "cache_complete", %{count: length(cached)})

      # Use rate-limited event loop for pending transactions
      pending_event_loop_with_rate_limit(
        conn,
        topics,
        endpoint,
        start_time,
        rate_limit,
        0,
        System.monotonic_time(:millisecond)
      )
    end
  end

  @doc """
  Stream new validated transaction events.
  Mirrors the Phoenix `transactions:new_transaction` channel.

  On connect, immediately sends cached transactions for page population.

  Events emitted:
  - transaction: New validated transaction
  """
  def new_transaction_events(conn, _params) do
    try do
      conn
      |> setup_sse_headers()
      |> send_chunked(200)
      |> stream_new_transactions_with_cache()
    rescue
      e ->
        Logger.error("[SSE] Error in new_transaction_events: #{inspect(e)}")

        conn
        |> setup_sse_headers()
        |> send_resp(500, "event: error\ndata: {\"message\": \"Internal server error\"}\n\n")
    end
  end

  defp stream_new_transactions_with_cache(conn) do
    topics = [:transactions]
    endpoint = "new_transactions"
    start_time = System.monotonic_time(:second)

    record_connection_opened(endpoint)

    Enum.each(topics, &Subscriber.subscribe/1)

    {:ok, conn} =
      send_sse_event(conn, "connected", %{
        entity: format_entity_filter(:new_transactions),
        timestamp: DateTime.utc_now()
      })

    # Send only the most recent cached transactions to populate the page
    # without overwhelming the connection on busy chains
    # Configurable via SSE_CACHE_LIMIT_TRANSACTIONS env var (default: 100)
    cached =
      Subscriber.get_cached_transactions()
      |> Enum.take(sse_cache_limit_transactions())

    conn =
      Enum.reduce(cached, conn, fn tx, acc_conn ->
        case send_sse_event(acc_conn, "transaction", tx) do
          {:ok, new_conn} ->
            record_event_sent(endpoint, "transaction")
            new_conn

          {:error, _} ->
            acc_conn
        end
      end)

    # Signal that initial cache is complete - frontend can start counting new txs from here
    {:ok, conn} = send_sse_event(conn, "cache_complete", %{count: length(cached)})

    entity_event_loop_with_cleanup(conn, topics, :new_transactions, endpoint, start_time)
  end

  @doc """
  Stream stats updates (exchange rate, transaction stats).
  Replaces polling for stats endpoints.

  On connect, immediately sends any cached stats so clients have current data
  without hitting the database. Then streams live updates.

  Events emitted:
  - exchange_rate: Price/market data updated
  - transaction_stats: Transaction statistics updated
  """
  def stats_events(conn, _params) do
    try do
      conn
      |> setup_sse_headers()
      |> send_chunked(200)
      |> stream_stats_with_cache()
    rescue
      e ->
        Logger.error("[SSE] Error in stats_events: #{inspect(e)}")

        conn
        |> setup_sse_headers()
        |> send_resp(500, "event: error\ndata: {\"message\": \"Internal server error\"}\n\n")
    end
  end

  defp stream_stats_with_cache(conn) do
    topics = [:exchange_rate, :transaction_stats]
    endpoint = "stats"
    start_time = System.monotonic_time(:second)

    record_connection_opened(endpoint)

    # Subscribe to topics
    Enum.each(topics, &Subscriber.subscribe/1)

    # Send connection message
    {:ok, conn} =
      send_sse_event(conn, "connected", %{
        entity: format_entity_filter(:stats),
        timestamp: DateTime.utc_now()
      })

    # Send cached values immediately so clients have current data
    conn = send_cached_stats(conn, endpoint)

    # Start event loop
    entity_event_loop_with_cleanup(conn, topics, :stats, endpoint, start_time)
  end

  defp send_cached_stats(conn, endpoint \\ "stats") do
    cached = Subscriber.get_cached_stats()

    conn =
      case Map.get(cached, :exchange_rate) do
        nil ->
          conn

        data ->
          case send_sse_event(conn, "exchange_rate", data) do
            {:ok, conn} ->
              record_event_sent(endpoint, "exchange_rate")
              conn

            {:error, _} ->
              conn
          end
      end

    case Map.get(cached, :transaction_stats) do
      nil ->
        conn

      data ->
        case send_sse_event(conn, "transaction_stats", data) do
          {:ok, conn} ->
            record_event_sent(endpoint, "transaction_stats")
            conn

          {:error, _} ->
            conn
        end
    end
  end

  defp setup_sse_headers(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> put_resp_header("access-control-allow-origin", "*")
  end

  defp parse_topics(%{"topics" => topics_param}) when is_binary(topics_param) do
    topics_param
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 in @valid_topics))
    |> Enum.map(&String.to_existing_atom/1)
  end

  defp parse_topics(_), do: [:all]

  defp parse_filters(params) do
    %{
      address: normalize_address(params["address"]),
      token: normalize_address(params["token"])
    }
  end

  defp normalize_address(nil), do: nil
  defp normalize_address(""), do: nil

  defp normalize_address(addr) when is_binary(addr) do
    addr
    |> String.downcase()
    |> String.trim()
  end

  defp subscribe_and_stream(conn, topics, filters) do
    # Subscribe to requested topics
    Enum.each(topics, &Subscriber.subscribe/1)

    # Send initial connection message
    {:ok, conn} =
      send_sse_event(conn, "connected", %{
        topics: topics,
        filters: filters,
        timestamp: DateTime.utc_now()
      })

    # Start event loop
    stream_events(conn, topics, filters)
  end

  defp stream_events(conn, topics, filters) do
    receive do
      {:nats_event, event_type, data} ->
        # Apply filters before sending
        filtered_data = apply_filters(event_type, data, filters)

        if filtered_data != nil and filtered_data != [] do
          case send_sse_event(conn, event_type, filtered_data) do
            {:ok, conn} ->
              stream_events(conn, topics, filters)

            {:error, _reason} ->
              cleanup(topics)
              conn
          end
        else
          # Data filtered out, continue listening
          stream_events(conn, topics, filters)
        end

      {:plug_conn, :sent} ->
        stream_events(conn, topics, filters)
    after
      # Send keepalive every 30 seconds
      30_000 ->
        case send_sse_comment(conn, "keepalive") do
          {:ok, conn} ->
            stream_events(conn, topics, filters)

          {:error, _reason} ->
            cleanup(topics)
            conn
        end
    end
  end

  # Apply address and token filters to event data
  defp apply_filters(_event_type, data, %{address: nil, token: nil}), do: data

  defp apply_filters(event_type, data, filters) when is_list(data) do
    filtered = Enum.filter(data, &matches_filters?(event_type, &1, filters))
    if Enum.empty?(filtered), do: nil, else: filtered
  end

  defp apply_filters(event_type, data, filters) when is_map(data) do
    if matches_filters?(event_type, data, filters), do: data, else: nil
  end

  defp apply_filters(_event_type, data, _filters), do: data

  # Check if a single event matches the filters
  defp matches_filters?(event_type, data, %{address: address, token: token}) do
    matches_address?(event_type, data, address) and matches_token?(event_type, data, token)
  end

  # Address filter matching
  defp matches_address?(_event_type, _data, nil), do: true

  defp matches_address?(:pending_transactions, data, address) do
    matches_hash?(data["from_address_hash"], address) or
      matches_hash?(data["to_address_hash"], address)
  end

  defp matches_address?(:transactions, data, address) do
    matches_hash?(data["from_address_hash"], address) or
      matches_hash?(data["to_address_hash"], address)
  end

  defp matches_address?(:token_transfers, data, address) do
    matches_hash?(data["from_address_hash"], address) or
      matches_hash?(data["to_address_hash"], address)
  end

  defp matches_address?(:addresses, data, address) do
    matches_hash?(data["hash"], address)
  end

  defp matches_address?(:address_coin_balances, data, address) do
    matches_hash?(data["address_hash"], address)
  end

  defp matches_address?(:address_token_balances, data, address) do
    matches_hash?(data["address_hash"], address)
  end

  defp matches_address?(:address_current_token_balances, data, address) do
    matches_hash?(data["address_hash"], address)
  end

  defp matches_address?(:internal_transactions, data, address) do
    matches_hash?(data["from_address_hash"], address) or
      matches_hash?(data["to_address_hash"], address)
  end

  defp matches_address?(:contract_verification, data, address) do
    matches_hash?(data["address_hash"], address)
  end

  defp matches_address?(:changed_bytecode, data, address) do
    matches_hash?(data["address_hash"], address)
  end

  # Global events - no address filter applies
  defp matches_address?(_event_type, _data, _address), do: true

  # Token filter matching
  defp matches_token?(_event_type, _data, nil), do: true

  defp matches_token?(:token_transfers, data, token) do
    matches_hash?(data["token_contract_address_hash"], token)
  end

  defp matches_token?(:address_token_balances, data, token) do
    matches_hash?(data["token_contract_address_hash"], token)
  end

  defp matches_token?(:address_current_token_balances, data, token) do
    # Check nested token_balances
    case data["token_balances"] do
      balances when is_list(balances) ->
        Enum.any?(balances, fn b ->
          matches_hash?(b["token_contract_address_hash"], token)
        end)

      _ ->
        false
    end
  end

  defp matches_token?(:token_total_supply, data, token) do
    matches_hash?(data["contract_address_hash"], token)
  end

  # Other events - no token filter applies
  defp matches_token?(_event_type, _data, _token), do: true

  # Case-insensitive hash comparison
  defp matches_hash?(nil, _filter), do: false

  defp matches_hash?(hash, filter) when is_binary(hash) and is_binary(filter) do
    String.downcase(hash) == filter
  end

  defp matches_hash?(_, _), do: false

  defp send_sse_event(conn, event_type, data) do
    event = "event: #{event_type}\ndata: #{Jason.encode!(data)}\n\n"
    chunk(conn, event)
  end

  # Send keepalive as an actual SSE event so the browser's EventSource.onmessage fires.
  # SSE comments (: comment) are NOT delivered to onmessage, which causes the frontend's
  # heartbeat timeout to expire and force reconnect if no data events arrive.
  defp send_sse_comment(conn, "keepalive") do
    chunk(conn, "event: keepalive\ndata: {}\n\n")
  end

  defp send_sse_comment(conn, comment) do
    chunk(conn, ": #{comment}\n\n")
  end

  # Send multiple events (used when NATS publishes a list, but frontend expects individual items)
  defp send_multi_events(conn, []), do: {:ok, conn}

  defp send_multi_events(conn, [{event_type, data} | rest]) do
    case send_sse_event(conn, event_type, data) do
      {:ok, conn} -> send_multi_events(conn, rest)
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup(topics) do
    Enum.each(topics, &Subscriber.unsubscribe/1)
  end

  # =============================================================================
  # Entity-Specific Event Streaming
  # =============================================================================

  defp normalize_hash(nil), do: nil
  defp normalize_hash(""), do: nil

  defp normalize_hash(hash) when is_binary(hash) do
    hash
    |> String.downcase()
    |> String.trim()
  end

  defp stream_entity_events(conn, topics, entity_filter) do
    endpoint = entity_to_endpoint(entity_filter)
    entity_type = entity_to_type(entity_filter)
    start_time = System.monotonic_time(:second)

    # Track subscription
    record_connection_opened(endpoint)
    record_subscription_opened(endpoint, entity_type)

    # Subscribe to requested topics
    Enum.each(topics, &Subscriber.subscribe/1)

    # Send initial connection message
    {:ok, conn} =
      send_sse_event(conn, "connected", %{
        entity: format_entity_filter(entity_filter),
        timestamp: DateTime.utc_now()
      })

    # Start event loop with metrics tracking
    entity_event_loop_with_subscription_cleanup(conn, topics, entity_filter, endpoint, entity_type, start_time)
  end

  defp entity_to_endpoint({:address, _}), do: "addresses"
  defp entity_to_endpoint({:transaction, _}), do: "transactions"
  defp entity_to_endpoint({:token, _}), do: "tokens"
  defp entity_to_endpoint(:blocks), do: "blocks"
  defp entity_to_endpoint(:pending_transactions), do: "pending_transactions"
  defp entity_to_endpoint(:new_transactions), do: "new_transactions"
  defp entity_to_endpoint(:stats), do: "stats"
  defp entity_to_endpoint(_), do: "unknown"

  defp entity_to_type({:address, _}), do: :address
  defp entity_to_type({:transaction, _}), do: :transaction
  defp entity_to_type({:token, _}), do: :token
  defp entity_to_type(_), do: :global

  defp format_entity_filter({:address, addr}), do: %{type: "address", hash: addr}
  defp format_entity_filter({:transaction, tx}), do: %{type: "transaction", hash: tx}
  defp format_entity_filter({:token, token}), do: %{type: "token", hash: token}
  defp format_entity_filter(:blocks), do: %{type: "blocks"}
  defp format_entity_filter(:pending_transactions), do: %{type: "pending_transactions"}
  defp format_entity_filter(:new_transactions), do: %{type: "new_transactions"}
  defp format_entity_filter(:stats), do: %{type: "stats"}

  defp entity_event_loop(conn, topics, entity_filter) do
    receive do
      {:nats_event, event_type, data} ->
        # Filter and transform events for this entity
        case filter_and_transform_for_entity(event_type, data, entity_filter) do
          nil ->
            # Event doesn't match this entity, continue
            entity_event_loop(conn, topics, entity_filter)

          # Handle multiple events (e.g., list of blocks from NATS)
          {:multi_event, events} ->
            case send_multi_events(conn, events) do
              {:ok, conn} ->
                entity_event_loop(conn, topics, entity_filter)

              {:error, _reason} ->
                cleanup(topics)
                conn
            end

          {channel_event, transformed_data} ->
            case send_sse_event(conn, channel_event, transformed_data) do
              {:ok, conn} ->
                entity_event_loop(conn, topics, entity_filter)

              {:error, _reason} ->
                cleanup(topics)
                conn
            end
        end

      {:plug_conn, :sent} ->
        entity_event_loop(conn, topics, entity_filter)
    after
      30_000 ->
        case send_sse_comment(conn, "keepalive") do
          {:ok, conn} ->
            entity_event_loop(conn, topics, entity_filter)

          {:error, _reason} ->
            cleanup(topics)
            conn
        end
    end
  end

  # =============================================================================
  # Entity Filtering and Event Transformation
  # =============================================================================

  # Address events - map NATS events to Phoenix channel event names
  defp filter_and_transform_for_entity(:pending_transactions, data, {:address, address}) do
    filtered = filter_by_address(data, address, ["from_address_hash", "to_address_hash"])
    if filtered, do: {"pending_transaction", filtered}, else: nil
  end

  defp filter_and_transform_for_entity(:transactions, data, {:address, address}) do
    filtered = filter_by_address(data, address, ["from_address_hash", "to_address_hash"])
    if filtered, do: {"transaction", filtered}, else: nil
  end

  defp filter_and_transform_for_entity(:token_transfers, data, {:address, address}) do
    filtered = filter_by_address(data, address, ["from_address_hash", "to_address_hash"])
    if filtered, do: {"token_transfer", filtered}, else: nil
  end

  defp filter_and_transform_for_entity(:address_coin_balances, data, {:address, address}) do
    filtered = filter_by_address(data, address, ["address_hash"])
    if filtered, do: {"coin_balance", filtered}, else: nil
  end

  defp filter_and_transform_for_entity(:address_token_balances, data, {:address, address}) do
    filtered = filter_by_address(data, address, ["address_hash"])
    if filtered, do: {"token_balance", filtered}, else: nil
  end

  defp filter_and_transform_for_entity(:address_current_token_balances, data, {:address, address}) do
    filtered = filter_by_address(data, address, ["address_hash"])
    if filtered, do: {"token_balance", filtered}, else: nil
  end

  defp filter_and_transform_for_entity(:internal_transactions, data, {:address, address}) do
    filtered = filter_by_address(data, address, ["from_address_hash", "to_address_hash"])
    if filtered, do: {"internal_transaction", filtered}, else: nil
  end

  defp filter_and_transform_for_entity(:contract_verification, data, {:address, address}) do
    filtered = filter_by_address(data, address, ["address_hash"])
    if filtered, do: {"verification_result", filtered}, else: nil
  end

  defp filter_and_transform_for_entity(:changed_bytecode, data, {:address, address}) do
    filtered = filter_by_address(data, address, ["address_hash"])
    if filtered, do: {"changed_bytecode", filtered}, else: nil
  end

  # Pending transaction events for transaction-specific watch - emit "pending" when tx is in mempool
  defp filter_and_transform_for_entity(:pending_transactions, data, {:transaction, tx_hash}) do
    filtered = filter_by_hash(data, tx_hash, "hash")
    if filtered, do: {"pending", filtered}, else: nil
  end

  # Transaction events - emit "collated" when tx is included in block
  defp filter_and_transform_for_entity(:transactions, data, {:transaction, tx_hash}) do
    filtered = filter_by_hash(data, tx_hash, "hash")
    if filtered, do: {"collated", filtered}, else: nil
  end

  # Raw trace events for transaction - traces are now available
  defp filter_and_transform_for_entity(:raw_traces, data, {:transaction, tx_hash}) do
    filtered = filter_by_hash(data, tx_hash, "transaction_hash")
    if filtered, do: {"raw_trace", filtered}, else: nil
  end

  # Token events
  defp filter_and_transform_for_entity(:token_transfers, data, {:token, token}) do
    filtered = filter_by_address(data, token, ["token_contract_address_hash"])
    if filtered, do: {"token_transfer", filtered}, else: nil
  end

  defp filter_and_transform_for_entity(:token_total_supply, data, {:token, token}) do
    filtered = filter_by_address(data, token, ["contract_address_hash"])
    if filtered, do: {"total_supply", filtered}, else: nil
  end

  # Block events - send each block as a separate event
  # NATS publishes blocks as a list, but frontend expects individual block objects
  defp filter_and_transform_for_entity(:blocks, data, :blocks) when is_list(data) do
    # Return special marker for multi-event handling
    {:multi_event, Enum.map(data, fn block -> {"new_block", block} end)}
  end

  defp filter_and_transform_for_entity(:blocks, data, :blocks) do
    {"new_block", data}
  end

  # Pending transaction events (global stream) - NATS sends as list
  defp filter_and_transform_for_entity(:pending_transactions, data, :pending_transactions) when is_list(data) do
    {:multi_event, Enum.map(data, fn tx -> {"pending_transaction", tx} end)}
  end

  defp filter_and_transform_for_entity(:pending_transactions, data, :pending_transactions) do
    {"pending_transaction", data}
  end

  # New validated transaction events (global stream) - NATS sends as list
  defp filter_and_transform_for_entity(:transactions, data, :new_transactions) when is_list(data) do
    {:multi_event, Enum.map(data, fn tx -> {"transaction", tx} end)}
  end

  defp filter_and_transform_for_entity(:transactions, data, :new_transactions) do
    {"transaction", data}
  end

  # Stats events
  defp filter_and_transform_for_entity(:exchange_rate, data, :stats) do
    {"exchange_rate", data}
  end

  defp filter_and_transform_for_entity(:transaction_stats, data, :stats) do
    {"transaction_stats", data}
  end

  # Catch-all - ignore unhandled event types for this entity
  defp filter_and_transform_for_entity(_event_type, _data, _entity_filter), do: nil

  # =============================================================================
  # Filter Helpers
  # =============================================================================

  # Filter list or single item by matching any of the specified address fields
  defp filter_by_address(data, address, fields) when is_list(data) do
    filtered = Enum.filter(data, &item_matches_address?(&1, address, fields))
    if Enum.empty?(filtered), do: nil, else: filtered
  end

  defp filter_by_address(data, address, fields) when is_map(data) do
    if item_matches_address?(data, address, fields), do: data, else: nil
  end

  defp filter_by_address(_data, _address, _fields), do: nil

  defp item_matches_address?(item, address, fields) do
    Enum.any?(fields, fn field ->
      matches_hash?(item[field], address)
    end)
  end

  # Filter by exact hash match
  defp filter_by_hash(data, hash, field) when is_list(data) do
    filtered = Enum.filter(data, &matches_hash?(&1[field], hash))
    if Enum.empty?(filtered), do: nil, else: filtered
  end

  defp filter_by_hash(data, hash, field) when is_map(data) do
    if matches_hash?(data[field], hash), do: data, else: nil
  end

  defp filter_by_hash(_data, _hash, _field), do: nil

  # =============================================================================
  # Instrumented Event Loop
  # =============================================================================

  # Event loop with proper cleanup on connection close
  # Uses 5s keepalive to detect client disconnects quickly
  defp entity_event_loop_with_cleanup(conn, topics, entity_filter, endpoint, start_time) do
    receive do
      {:nats_event, event_type, data} ->
        # Filter and transform events for this entity
        case filter_and_transform_for_entity(event_type, data, entity_filter) do
          nil ->
            # Event doesn't match this entity, continue
            entity_event_loop_with_cleanup(conn, topics, entity_filter, endpoint, start_time)

          # Handle multiple events (e.g., list of blocks from NATS)
          {:multi_event, events} ->
            case send_multi_events_with_metrics(conn, events, endpoint) do
              {:ok, conn} ->
                entity_event_loop_with_cleanup(conn, topics, entity_filter, endpoint, start_time)

              {:error, reason} ->
                cleanup_with_metrics(topics, endpoint, start_time, reason)
                conn
            end

          {channel_event, transformed_data} ->
            case send_sse_event(conn, channel_event, transformed_data) do
              {:ok, conn} ->
                record_event_sent(endpoint, channel_event)
                entity_event_loop_with_cleanup(conn, topics, entity_filter, endpoint, start_time)

              {:error, reason} ->
                cleanup_with_metrics(topics, endpoint, start_time, reason)
                conn
            end
        end

      {:plug_conn, :sent} ->
        entity_event_loop_with_cleanup(conn, topics, entity_filter, endpoint, start_time)
    after
      # Use 5s keepalive to detect disconnects quickly
      5_000 ->
        case send_sse_comment(conn, "keepalive") do
          {:ok, conn} ->
            entity_event_loop_with_cleanup(conn, topics, entity_filter, endpoint, start_time)

          {:error, reason} ->
            cleanup_with_metrics(topics, endpoint, start_time, reason)
            conn
        end
    end
  end

  # Original event loop (kept for backwards compatibility, uses 30s keepalive)
  defp entity_event_loop_with_metrics(conn, topics, entity_filter, endpoint, start_time) do
    receive do
      {:nats_event, event_type, data} ->
        case filter_and_transform_for_entity(event_type, data, entity_filter) do
          nil ->
            entity_event_loop_with_metrics(conn, topics, entity_filter, endpoint, start_time)

          {:multi_event, events} ->
            case send_multi_events_with_metrics(conn, events, endpoint) do
              {:ok, conn} ->
                entity_event_loop_with_metrics(conn, topics, entity_filter, endpoint, start_time)

              {:error, reason} ->
                cleanup_with_metrics(topics, endpoint, start_time, reason)
                conn
            end

          {channel_event, transformed_data} ->
            case send_sse_event(conn, channel_event, transformed_data) do
              {:ok, conn} ->
                record_event_sent(endpoint, channel_event)
                entity_event_loop_with_metrics(conn, topics, entity_filter, endpoint, start_time)

              {:error, reason} ->
                cleanup_with_metrics(topics, endpoint, start_time, reason)
                conn
            end
        end

      {:plug_conn, :sent} ->
        entity_event_loop_with_metrics(conn, topics, entity_filter, endpoint, start_time)
    after
      5_000 ->
        case send_sse_comment(conn, "keepalive") do
          {:ok, conn} ->
            entity_event_loop_with_metrics(conn, topics, entity_filter, endpoint, start_time)

          {:error, reason} ->
            cleanup_with_metrics(topics, endpoint, start_time, reason)
            conn
        end
    end
  end

  defp send_multi_events_with_metrics(conn, [], _endpoint), do: {:ok, conn}

  defp send_multi_events_with_metrics(conn, [{event_type, data} | rest], endpoint) do
    case send_sse_event(conn, event_type, data) do
      {:ok, conn} ->
        record_event_sent(endpoint, event_type)
        send_multi_events_with_metrics(conn, rest, endpoint)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_with_metrics(topics, endpoint, start_time, reason) do
    Logger.info("[SSE] Cleaning up #{endpoint} connection, reason: #{inspect(reason)}")
    Enum.each(topics, &Subscriber.unsubscribe/1)

    # Record connection metrics
    duration = System.monotonic_time(:second) - start_time
    record_connection_closed(endpoint, reason, duration)
  end

  defp cleanup_with_subscription_metrics(topics, endpoint, entity_type, start_time, reason) do
    Enum.each(topics, &Subscriber.unsubscribe/1)

    # Record connection and subscription metrics
    duration = System.monotonic_time(:second) - start_time
    record_connection_closed(endpoint, reason, duration)
    record_subscription_closed(endpoint, entity_type)
  end

  # Event loop with subscription type tracking and proper cleanup
  defp entity_event_loop_with_subscription_cleanup(conn, topics, entity_filter, endpoint, entity_type, start_time) do
    receive do
      {:nats_event, event_type, data} ->
        # Filter and transform events for this entity
        case filter_and_transform_for_entity(event_type, data, entity_filter) do
          nil ->
            # Event doesn't match this entity, continue
            entity_event_loop_with_subscription_cleanup(conn, topics, entity_filter, endpoint, entity_type, start_time)

          # Handle multiple events (e.g., list of blocks from NATS)
          {:multi_event, events} ->
            case send_multi_events_with_metrics(conn, events, endpoint) do
              {:ok, conn} ->
                entity_event_loop_with_subscription_cleanup(
                  conn,
                  topics,
                  entity_filter,
                  endpoint,
                  entity_type,
                  start_time
                )

              {:error, reason} ->
                cleanup_with_subscription_metrics(topics, endpoint, entity_type, start_time, reason)
                conn
            end

          {channel_event, transformed_data} ->
            case send_sse_event(conn, channel_event, transformed_data) do
              {:ok, conn} ->
                record_event_sent(endpoint, channel_event)

                entity_event_loop_with_subscription_cleanup(
                  conn,
                  topics,
                  entity_filter,
                  endpoint,
                  entity_type,
                  start_time
                )

              {:error, reason} ->
                cleanup_with_subscription_metrics(topics, endpoint, entity_type, start_time, reason)
                conn
            end
        end

      {:plug_conn, :sent} ->
        entity_event_loop_with_subscription_cleanup(conn, topics, entity_filter, endpoint, entity_type, start_time)
    after
      # Use 5s keepalive to detect disconnects quickly
      5_000 ->
        case send_sse_comment(conn, "keepalive") do
          {:ok, conn} ->
            entity_event_loop_with_subscription_cleanup(conn, topics, entity_filter, endpoint, entity_type, start_time)

          {:error, reason} ->
            cleanup_with_subscription_metrics(topics, endpoint, entity_type, start_time, reason)
            conn
        end
    end
  end

  # =============================================================================
  # Rate-Limited Event Loop for Pending Transactions
  # =============================================================================

  # Rate-limited event loop that drops excess pending transactions
  # sent_this_second: count of pending txs sent in current second
  # second_start: monotonic time (ms) when current second started
  defp pending_event_loop_with_rate_limit(
         conn,
         topics,
         endpoint,
         start_time,
         rate_limit,
         sent_this_second,
         second_start
       ) do
    now_ms = System.monotonic_time(:millisecond)
    # Check if we've entered a new second
    {sent_count, sec_start} =
      if now_ms - second_start >= 1000 do
        {0, now_ms}
      else
        {sent_this_second, second_start}
      end

    receive do
      {:nats_event, :pending_transactions, data} ->
        # Check rate limit before sending
        if sent_count < rate_limit do
          # Filter and transform for pending_transactions entity
          case filter_and_transform_for_entity(:pending_transactions, data, :pending_transactions) do
            nil ->
              pending_event_loop_with_rate_limit(conn, topics, endpoint, start_time, rate_limit, sent_count, sec_start)

            {:multi_event, events} ->
              # Send only up to rate limit, drop the rest
              remaining_budget = rate_limit - sent_count
              events_to_send = Enum.take(events, remaining_budget)
              dropped = length(events) - length(events_to_send)

              if dropped > 0 do
                Logger.debug("[SSE] Rate limited: dropped #{dropped} pending txs")
              end

              case send_multi_events_with_metrics(conn, events_to_send, endpoint) do
                {:ok, conn} ->
                  pending_event_loop_with_rate_limit(
                    conn,
                    topics,
                    endpoint,
                    start_time,
                    rate_limit,
                    sent_count + length(events_to_send),
                    sec_start
                  )

                {:error, reason} ->
                  cleanup_with_metrics(topics, endpoint, start_time, reason)
                  conn
              end

            {channel_event, transformed_data} ->
              case send_sse_event(conn, channel_event, transformed_data) do
                {:ok, conn} ->
                  record_event_sent(endpoint, channel_event)

                  pending_event_loop_with_rate_limit(
                    conn,
                    topics,
                    endpoint,
                    start_time,
                    rate_limit,
                    sent_count + 1,
                    sec_start
                  )

                {:error, reason} ->
                  cleanup_with_metrics(topics, endpoint, start_time, reason)
                  conn
              end
          end
        else
          # Rate limited - drop this event
          pending_event_loop_with_rate_limit(conn, topics, endpoint, start_time, rate_limit, sent_count, sec_start)
        end

      {:nats_event, _event_type, _data} ->
        # Ignore non-pending events
        pending_event_loop_with_rate_limit(conn, topics, endpoint, start_time, rate_limit, sent_count, sec_start)

      {:plug_conn, :sent} ->
        pending_event_loop_with_rate_limit(conn, topics, endpoint, start_time, rate_limit, sent_count, sec_start)
    after
      5_000 ->
        case send_sse_comment(conn, "keepalive") do
          {:ok, conn} ->
            pending_event_loop_with_rate_limit(
              conn,
              topics,
              endpoint,
              start_time,
              rate_limit,
              0,
              System.monotonic_time(:millisecond)
            )

          {:error, reason} ->
            cleanup_with_metrics(topics, endpoint, start_time, reason)
            conn
        end
    end
  end

  # =============================================================================
  # Metrics Helper Functions
  # =============================================================================

  defp record_connection_opened(endpoint) do
    # Increment the connection counter
    if Code.ensure_loaded?(SSEInstrumenter) do
      try do
        SSEInstrumenter.sse_connection_opened(endpoint)
      rescue
        _ -> :ok
      end
    end

    # Register with ConnectionTracker for proper cleanup on process death
    # The tracker will monitor this process and decrement the counter when it dies
    # (handles both graceful closes and Cowboy killing the process on TCP close)
    ConnectionTracker.track(self(), endpoint)
  end

  # NOTE: We no longer decrement the counter here. The ConnectionTracker monitors
  # each handler process and decrements when it dies (for any reason). This ensures
  # cleanup happens even when Cowboy kills the process on client disconnect.
  defp record_connection_closed(endpoint, _reason, duration) do
    if Code.ensure_loaded?(SSEInstrumenter) do
      try do
        # Only record duration - counter decrement is handled by ConnectionTracker
        SSEInstrumenter.sse_connection_duration(endpoint, duration)
      rescue
        _ -> :ok
      end
    end
  end

  defp record_event_sent(endpoint, event_type) do
    if Code.ensure_loaded?(SSEInstrumenter) do
      try do
        SSEInstrumenter.sse_event_sent(endpoint, event_type)
      rescue
        _ -> :ok
      end
    end
  end

  defp record_subscription_opened(endpoint, entity_type) do
    if Code.ensure_loaded?(ApiInstrumenter) do
      try do
        ApiInstrumenter.sse_subscription_opened(endpoint, entity_type)
      rescue
        _ -> :ok
      end
    end
  end

  defp record_subscription_closed(endpoint, entity_type) do
    if Code.ensure_loaded?(ApiInstrumenter) do
      try do
        ApiInstrumenter.sse_subscription_closed(endpoint, entity_type)
      rescue
        _ -> :ok
      end
    end
  end
end
