defmodule BlockScoutWeb.Nats.Subscriber do
  @moduledoc """
  Subscribes to NATS topics and forwards events to SSE clients.

  This module runs on API servers. It subscribes to NATS topics published
  by the indexer and broadcasts events to connected SSE clients via a
  local Registry.

  ## JetStream Replay on Startup

  When the subscriber starts (or reconnects), it replays messages from
  JetStream streams to populate the cache immediately. This ensures that
  even after an API server restart, clients get populated pages without
  waiting for new events or hitting the database.

  Replayed streams:
  - BLOCKSCOUT_BLOCKS - Last 50 blocks
  - BLOCKSCOUT_TRANSACTIONS - Last 100 transactions
  - BLOCKSCOUT_PENDING - Last 5000 pending transactions (30 min max age)
  - BLOCKSCOUT_EXCHANGE_RATE - Latest exchange rate (1 message)
  - BLOCKSCOUT_TX_STATS - Latest transaction stats (1 message)

  ## Usage

  SSE controllers register with this subscriber to receive events:

      BlockScoutWeb.Nats.Subscriber.subscribe(:blocks)

  Events are delivered as messages:

      {:nats_event, :blocks, data}

  ## Caching

  Recent events are cached so new SSE clients receive enough data to
  populate the UI immediately without hitting the database:

  - `blocks` - Last 50 blocks (sorted by number descending)
  - `transactions` - Last 50 confirmed transactions
  - `pending_transactions` - Up to 5000 pending transactions (with lifecycle management)
  - `exchange_rate` - Latest exchange rate data
  - `transaction_stats` - Latest transaction statistics

  ### Pending Transaction Lifecycle

  Pending transactions are removed from cache when:
  - They get mined (appear in confirmed transactions)
  - They expire (older than 30 minutes)
  - Periodic cleanup runs (every 5 minutes)

  Use `get_cached/1` for raw values, or the typed helpers:
  - `get_cached_blocks/0` - Returns list of cached blocks
  - `get_cached_transactions/0` - Returns list of cached transactions
  - `get_cached_pending_transactions/0` - Returns list of cached pending txs
  - `get_cached_stats/0` - Returns map of cached stats
  """

  use GenServer

  require Logger

  alias BlockScoutWeb.Prometheus.{ApiInstrumenter, SSEInstrumenter}

  @nats_prefix "blockscout."
  @cache_table :nats_subscriber_cache
  # Number of items to cache for page population
  @cache_limit_blocks 50
  @cache_limit_transactions 50
  @cache_limit_pending_transactions 5000
  # Max age for pending transactions in cache (30 minutes)
  @pending_tx_max_age_ms 30 * 60 * 1000

  # JetStream streams to replay on startup (matches publisher configuration)
  @jetstream_streams [
    %{name: "BLOCKSCOUT_BLOCKS", topic: "blocks"},
    %{name: "BLOCKSCOUT_TRANSACTIONS", topic: "transactions"},
    %{name: "BLOCKSCOUT_PENDING", topic: "pending_transactions"},
    %{name: "BLOCKSCOUT_EXCHANGE_RATE", topic: "exchange_rate"},
    %{name: "BLOCKSCOUT_TX_STATS", topic: "transaction_stats"}
  ]

  # All topics published by Explorer.Nats.Publisher
  @nats_topics ~w(
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

  # Registry for SSE client subscriptions
  def registry_name, do: BlockScoutWeb.Nats.Registry

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # All valid event types for subscription
  @valid_event_types [
    :blocks,
    :pending_transactions,
    :transactions,
    :token_transfers,
    :addresses,
    :address_coin_balances,
    :address_token_balances,
    :address_current_token_balances,
    :block_rewards,
    :internal_transactions,
    :last_block_number,
    :token_total_supply,
    :contract_verification,
    :changed_bytecode,
    :exchange_rate,
    :transaction_stats,
    :raw_traces,
    :all
  ]

  @doc """
  Subscribe the calling process to a specific event type.
  Events will be sent as {:nats_event, event_type, data} messages.
  """
  def subscribe(event_type) when event_type in @valid_event_types do
    Registry.register(registry_name(), event_type, [])
  end

  @doc """
  Unsubscribe the calling process from an event type.
  """
  def unsubscribe(event_type) do
    Registry.unregister(registry_name(), event_type)
  end

  @doc """
  Get cached value for a specific event type.
  Returns nil if no cached value exists.

  Cached event types:
  - :exchange_rate - Latest exchange rate data
  - :transaction_stats - Latest transaction statistics
  - :blocks - List of recent blocks (up to #{@cache_limit_blocks})
  - :transactions - List of recent transactions (up to #{@cache_limit_transactions})
  - :pending_transactions - List of pending transactions (up to #{@cache_limit_pending_transactions})
  """
  def get_cached(event_type) when event_type in [:exchange_rate, :transaction_stats, :blocks, :transactions, :pending_transactions] do
    case :ets.lookup(@cache_table, event_type) do
      [{^event_type, data}] -> data
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def get_cached(_event_type), do: nil

  @doc """
  Get all cached stats (exchange_rate and transaction_stats).
  Returns a map with available cached values.
  """
  def get_cached_stats do
    %{}
    |> maybe_add_cached(:exchange_rate)
    |> maybe_add_cached(:transaction_stats)
  end

  @doc """
  Get cached blocks as a list. Returns empty list if no cache.
  """
  def get_cached_blocks do
    case get_cached(:blocks) do
      nil -> []
      blocks when is_list(blocks) -> blocks
      block when is_map(block) -> [block]
    end
  end

  @doc """
  Get cached transactions as a list. Returns empty list if no cache.
  """
  def get_cached_transactions do
    case get_cached(:transactions) do
      nil -> []
      txs when is_list(txs) -> txs
      tx when is_map(tx) -> [tx]
    end
  end

  @doc """
  Get cached pending transactions as a list. Returns empty list if no cache.
  Automatically filters out expired entries and returns just the transaction data.
  """
  def get_cached_pending_transactions do
    now = System.system_time(:millisecond)
    cutoff = now - @pending_tx_max_age_ms

    case get_cached(:pending_transactions) do
      nil -> []
      txs when is_list(txs) ->
        txs
        |> Enum.filter(fn
          %{cached_at: ts} -> ts > cutoff
          _ -> true  # Keep items without timestamp (shouldn't happen)
        end)
        |> Enum.map(fn
          %{data: data} -> data
          other -> other  # Handle legacy format
        end)
      tx when is_map(tx) -> [tx]
    end
  end

  defp maybe_add_cached(acc, key) do
    case get_cached(key) do
      nil -> acc
      data -> Map.put(acc, key, data)
    end
  end

  @impl GenServer
  def init(opts) do
    # Create ETS table for caching stats
    :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])

    # Schedule periodic cleanup of expired pending transactions
    schedule_pending_cleanup()

    nats_url = Keyword.get(opts, :nats_url) || Application.get_env(:block_scout_web, :nats_url)

    if nats_url do
      Logger.info("[Nats.Subscriber] Starting with NATS URL: #{nats_url}")

      uri = URI.parse(nats_url)
      host = uri.host || "localhost"
      port = uri.port || 4222

      case start_nats_connection(host, port) do
        {:ok, conn} ->
          # Replay JetStream messages to populate cache before subscribing to live updates
          # This is non-fatal - if JetStream isn't available, we just start with empty cache
          try do
            replay_jetstream_messages(conn)
          rescue
            e ->
              Logger.warning("[Nats.Subscriber] JetStream replay failed (non-fatal): #{inspect(e)}")
          catch
            :exit, reason ->
              Logger.warning("[Nats.Subscriber] JetStream replay exited (non-fatal): #{inspect(reason)}")
          end

          # Subscribe to all topics for live updates
          subscriptions = subscribe_to_topics(conn)
          Logger.info("[Nats.Subscriber] Connected and subscribed to #{length(subscriptions)} topics")
          record_connection_status(true)
          {:ok, %{conn: conn, subscriptions: subscriptions, connected: true}}

        {:error, reason} ->
          Logger.warning("[Nats.Subscriber] Failed to connect to NATS: #{inspect(reason)}, will retry")
          record_connection_status(false)
          schedule_reconnect()
          {:ok, %{conn: nil, subscriptions: [], connected: false, host: host, port: port}}
      end
    else
      Logger.info("[Nats.Subscriber] NATS URL not configured, subscriber disabled")
      :ignore
    end
  end

  @impl GenServer
  def handle_info({:msg, %{topic: topic, body: body}}, state) do
    event_type = topic_to_event_type(topic)

    # Record metrics for received event
    record_event_received(event_type)

    case Jason.decode(body) do
      {:ok, decoded} ->
        # Unwrap envelope if present (new format with timestamp)
        # Format: %{"_ts" => unix_ms, "d" => actual_data}
        # Falls back to raw data for backward compatibility
        {data, maybe_ts} = unwrap_envelope(decoded)

        # Record NATS lag if timestamp was present
        if maybe_ts do
          record_nats_lag(topic, maybe_ts)
        end

        # Cache certain event types for new SSE clients
        maybe_cache_event(event_type, data)
        broadcast_to_subscribers(event_type, data)

      {:error, reason} ->
        Logger.warning("[Nats.Subscriber] Failed to decode message: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(:reconnect, %{host: host, port: port} = state) do
    case start_nats_connection(host, port) do
      {:ok, conn} ->
        # Replay JetStream messages to catch up on what we missed (non-fatal)
        try do
          replay_jetstream_messages(conn)
        rescue
          e ->
            Logger.warning("[Nats.Subscriber] JetStream replay on reconnect failed (non-fatal): #{inspect(e)}")
        catch
          :exit, reason ->
            Logger.warning("[Nats.Subscriber] JetStream replay on reconnect exited (non-fatal): #{inspect(reason)}")
        end

        subscriptions = subscribe_to_topics(conn)
        Logger.info("[Nats.Subscriber] Reconnected to NATS")
        record_connection_status(true)
        {:noreply, %{state | conn: conn, subscriptions: subscriptions, connected: true}}

      {:error, _reason} ->
        schedule_reconnect()
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.warning("[Nats.Subscriber] NATS connection lost: #{inspect(reason)}")
    record_connection_status(false)
    schedule_reconnect()
    {:noreply, %{state | conn: nil, subscriptions: [], connected: false}}
  end

  def handle_info(:cleanup_pending, state) do
    cleanup_expired_pending()
    schedule_pending_cleanup()
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{conn: conn, subscriptions: subs}) when not is_nil(conn) do
    Enum.each(subs, fn sid -> Gnat.unsub(conn, sid) end)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Private functions

  defp start_nats_connection(host, port) do
    Gnat.start_link(%{host: host, port: port})
  end

  # Replay messages from JetStream streams to populate cache on startup
  defp replay_jetstream_messages(conn) do
    Logger.info("[Nats.Subscriber] Replaying JetStream messages to populate cache...")

    Enum.each(@jetstream_streams, fn stream_config ->
      replay_stream(conn, stream_config.name, stream_config.topic)
    end)

    Logger.info("[Nats.Subscriber] JetStream replay complete")
  end

  defp replay_stream(conn, stream_name, topic) do
    # Use a push consumer with a unique inbox - more reliable in clustered NATS
    # because we subscribe first, then create consumer that delivers to our inbox
    consumer_name = "replay-#{:erlang.unique_integer([:positive])}"
    inbox = "_INBOX.replay.#{consumer_name}"

    # Collect messages in a process dictionary during subscription
    parent = self()
    messages_ref = make_ref()

    # Start a temporary process to collect messages
    collector = spawn(fn ->
      collect_replay_messages(parent, messages_ref, topic, [])
    end)

    # Subscribe to the inbox before creating consumer
    {:ok, sub} = Gnat.sub(conn, collector, inbox)

    # Create a push consumer that delivers to our inbox
    create_request = Jason.encode!(%{
      stream_name: stream_name,
      config: %{
        name: consumer_name,
        deliver_subject: inbox,
        deliver_policy: "all",
        ack_policy: "none",
        max_deliver: 1,
        inactive_threshold: 10_000_000_000,  # 10 seconds in nanoseconds
        # Stop after delivering all messages
        max_pending: 5000
      }
    })

    # Use pub instead of request - we don't need the response for push consumers
    :ok = Gnat.pub(conn, "$JS.API.CONSUMER.CREATE.#{stream_name}.#{consumer_name}", create_request)

    # Wait for messages to arrive (with timeout)
    # Give it up to 5 seconds to receive all messages
    Process.sleep(2000)

    # Signal collector to send us the results
    send(collector, {:get_messages, self(), messages_ref})

    messages = receive do
      {:replay_messages, ^messages_ref, msgs} -> msgs
    after
      5000 -> []
    end

    # Unsubscribe and cleanup
    Gnat.unsub(conn, sub)

    # Try to delete the consumer (fire and forget)
    spawn(fn ->
      Process.sleep(100)
      Gnat.pub(conn, "$JS.API.CONSUMER.DELETE.#{stream_name}.#{consumer_name}", "")
    end)

    count = length(messages)
    if count > 0 do
      Logger.info("[Nats.Subscriber] Replayed #{count} messages from #{stream_name}")
    else
      Logger.debug("[Nats.Subscriber] No messages to replay from #{stream_name}")
    end

  rescue
    e ->
      Logger.warning("[Nats.Subscriber] Error replaying #{stream_name}: #{inspect(e)}")
  end

  # Collector process that receives push consumer messages
  defp collect_replay_messages(parent, ref, topic, acc) do
    receive do
      {:msg, %{body: body}} ->
        # Process and cache the message
        process_replay_message(topic, body)
        collect_replay_messages(parent, ref, topic, [body | acc])

      {:get_messages, pid, ^ref} ->
        send(pid, {:replay_messages, ref, acc})

    after
      5000 ->
        # Timeout - send what we have
        send(parent, {:replay_messages, ref, acc})
    end
  end

  defp process_replay_message(topic, data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} -> process_replay_message(topic, decoded)
      {:error, _} -> :ok
    end
  end

  defp process_replay_message(topic, decoded) when is_map(decoded) or is_list(decoded) do
    # Unwrap envelope if present
    {data, _ts} = unwrap_envelope(decoded)

    event_type = String.to_existing_atom(topic)
    maybe_cache_event(event_type, data)
  rescue
    _ -> :ok
  end

  defp process_replay_message(_, _), do: :ok

  defp subscribe_to_topics(conn) do
    Enum.map(@nats_topics, fn topic ->
      nats_topic = @nats_prefix <> topic
      {:ok, sid} = Gnat.sub(conn, self(), nats_topic)
      Logger.debug("[Nats.Subscriber] Subscribed to #{nats_topic}")
      sid
    end)
  end

  defp schedule_reconnect do
    Process.send_after(self(), :reconnect, 5_000)
  end

  defp schedule_pending_cleanup do
    # Run cleanup every 5 minutes
    Process.send_after(self(), :cleanup_pending, 5 * 60 * 1000)
  end

  defp cleanup_expired_pending do
    now = System.system_time(:millisecond)
    cutoff = now - @pending_tx_max_age_ms

    case :ets.lookup(@cache_table, :pending_transactions) do
      [{:pending_transactions, pending}] when is_list(pending) ->
        before_count = length(pending)
        filtered = Enum.filter(pending, fn
          %{cached_at: ts} -> ts > cutoff
          _ -> false
        end)
        after_count = length(filtered)

        if before_count != after_count do
          :ets.insert(@cache_table, {:pending_transactions, filtered})
          Logger.debug("[Nats.Subscriber] Cleaned up #{before_count - after_count} expired pending transactions")
        end

      _ -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp topic_to_event_type(topic) do
    topic
    |> String.replace_prefix(@nats_prefix, "")
    |> String.to_existing_atom()
  rescue
    _ -> :unknown
  end

  defp broadcast_to_subscribers(event_type, data) do
    # Broadcast to specific event subscribers
    Registry.dispatch(registry_name(), event_type, fn entries ->
      for {pid, _} <- entries do
        send(pid, {:nats_event, event_type, data})
      end
    end)

    # Also broadcast to :all subscribers
    Registry.dispatch(registry_name(), :all, fn entries ->
      for {pid, _} <- entries do
        send(pid, {:nats_event, event_type, data})
      end
    end)
  end

  # Cache stats events so new SSE clients get current data immediately
  # Stats are simple key-value overwrites
  defp maybe_cache_event(event_type, data) when event_type in [:exchange_rate, :transaction_stats] do
    :ets.insert(@cache_table, {event_type, data})
  rescue
    ArgumentError -> :ok
  end

  # Blocks maintain a rolling list of recent blocks
  defp maybe_cache_event(:blocks, data) do
    cache_list_item(:blocks, data, @cache_limit_blocks, &get_block_number/1)
  end

  # Transactions maintain a rolling list of recent transactions
  # Also removes mined transactions from pending cache
  defp maybe_cache_event(:transactions, data) do
    cache_list_item(:transactions, data, @cache_limit_transactions, nil)
    # Remove mined transactions from pending cache
    remove_from_pending_cache(data)
  end

  # Pending transactions maintain a rolling list with timestamps for expiry
  defp maybe_cache_event(:pending_transactions, data) do
    cache_pending_transactions(data)
  end

  defp maybe_cache_event(_event_type, _data), do: :ok

  # Cache a list item, maintaining size limit and optional sorting
  defp cache_list_item(key, new_data, limit, sort_fn) do
    new_items = if is_list(new_data), do: new_data, else: [new_data]

    current = case :ets.lookup(@cache_table, key) do
      [{^key, list}] when is_list(list) -> list
      _ -> []
    end

    # Prepend new items and dedupe by hash
    updated = dedupe_by_hash(new_items ++ current)

    # Sort if sort function provided (blocks by number descending)
    updated = if sort_fn, do: Enum.sort_by(updated, sort_fn, :desc), else: updated

    # Trim to limit
    updated = Enum.take(updated, limit)

    :ets.insert(@cache_table, {key, updated})
  rescue
    ArgumentError -> :ok
  end

  # Deduplicate items by their hash field
  defp dedupe_by_hash(items) do
    items
    |> Enum.uniq_by(fn item ->
      item["hash"] || item["transaction_hash"] || item
    end)
  end

  # Extract block height for sorting (matches API v2 format)
  defp get_block_number(block) do
    # Check for "height" first (API v2 format), then "number" for backward compatibility
    case block["height"] || block["number"] do
      n when is_integer(n) -> n
      n when is_binary(n) -> String.to_integer(n)
      _ -> 0
    end
  end

  # Cache pending transactions with timestamps for expiry tracking
  defp cache_pending_transactions(new_data) do
    now = System.system_time(:millisecond)
    new_items = if is_list(new_data), do: new_data, else: [new_data]

    # Add timestamp to new items
    new_with_ts = Enum.map(new_items, fn item ->
      %{data: item, cached_at: now}
    end)

    current = case :ets.lookup(@cache_table, :pending_transactions) do
      [{:pending_transactions, list}] when is_list(list) -> list
      _ -> []
    end

    # Filter out expired entries and dedupe
    cutoff = now - @pending_tx_max_age_ms
    valid_current = Enum.filter(current, fn
      %{cached_at: ts} -> ts > cutoff
      _ -> false
    end)

    # Merge new with existing, dedupe by hash
    updated = dedupe_pending_by_hash(new_with_ts ++ valid_current)

    # Trim to limit
    updated = Enum.take(updated, @cache_limit_pending_transactions)

    :ets.insert(@cache_table, {:pending_transactions, updated})
  rescue
    ArgumentError -> :ok
  end

  # Remove mined transactions from pending cache
  defp remove_from_pending_cache(mined_data) do
    mined_items = if is_list(mined_data), do: mined_data, else: [mined_data]
    mined_hashes = MapSet.new(mined_items, fn item ->
      String.downcase(item["hash"] || "")
    end)

    case :ets.lookup(@cache_table, :pending_transactions) do
      [{:pending_transactions, pending}] when is_list(pending) ->
        filtered = Enum.reject(pending, fn
          %{data: item} ->
            hash = String.downcase(item["hash"] || "")
            MapSet.member?(mined_hashes, hash)
          _ -> false
        end)
        :ets.insert(@cache_table, {:pending_transactions, filtered})

      _ -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # Dedupe pending transactions by hash (items have %{data: ..., cached_at: ...} structure)
  defp dedupe_pending_by_hash(items) do
    items
    |> Enum.uniq_by(fn
      %{data: item} -> String.downcase(item["hash"] || "")
      item -> String.downcase(item["hash"] || "")
    end)
  end

  # =============================================================================
  # Metrics Helper Functions
  # =============================================================================

  defp record_event_received(event_type) do
    if Code.ensure_loaded?(SSEInstrumenter) do
      try do
        SSEInstrumenter.nats_event_received(event_type)
      rescue
        _ -> :ok
      end
    end
  end

  defp record_connection_status(connected) do
    if Code.ensure_loaded?(SSEInstrumenter) do
      try do
        SSEInstrumenter.nats_subscriber_connected(connected)
      rescue
        _ -> :ok
      end
    end
  end

  defp record_nats_lag(topic, published_ts) do
    if Code.ensure_loaded?(ApiInstrumenter) do
      try do
        now = System.system_time(:millisecond)
        lag_seconds = max(0, now - published_ts) / 1000.0
        # Strip prefix for cleaner labels
        clean_topic = String.replace_prefix(topic, @nats_prefix, "")
        ApiInstrumenter.nats_message_lag(clean_topic, lag_seconds)
      rescue
        _ -> :ok
      end
    end
  end

  # Unwrap envelope format: %{"_ts" => unix_ms, "d" => actual_data}
  # Returns {data, timestamp} or {data, nil} for backward compatibility
  defp unwrap_envelope(%{"_ts" => ts, "d" => data}) when is_integer(ts) do
    {data, ts}
  end

  # Legacy format (no envelope) - return as-is for maps and lists
  defp unwrap_envelope(data) when is_map(data) or is_list(data) do
    {data, nil}
  end
end
