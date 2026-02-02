defmodule Explorer.Nats.Publisher do
  @moduledoc """
  Publishes chain events to NATS for distribution to API servers.

  This module runs on the indexer and listens to chain events (new blocks,
  transactions, etc.) and publishes them to NATS topics. API servers subscribe
  to these topics and push updates to clients via SSE.

  ## Architecture

  The indexer PUBLISHES events to NATS (does not subscribe).
  API servers SUBSCRIBE to NATS topics via BlockScoutWeb.Nats.Subscriber.

  ## JetStream vs Core NATS

  Some topics use JetStream for message persistence and replay:
  - `blockscout.blocks` - Last 50 blocks retained
  - `blockscout.transactions` - Last 50 transactions retained
  - `blockscout.pending_transactions` - Last 5000 pending txs, 30 min max age
  - `blockscout.exchange_rate` - Last value retained
  - `blockscout.transaction_stats` - Last value retained

  This allows API servers to populate their cache on startup by replaying
  recent messages, ensuring users don't see empty pages after server restarts.

  Other topics use Core NATS (fire-and-forget) as they don't need replay.

  ## NATS Topics

  - `blockscout.blocks` - New blocks (JetStream)
  - `blockscout.pending_transactions` - Pending (mempool) transactions (JetStream)
  - `blockscout.transactions` - Confirmed transactions (JetStream)
  - `blockscout.exchange_rate` - Exchange rate updates (JetStream)
  - `blockscout.transaction_stats` - Transaction statistics (JetStream)
  - `blockscout.token_transfers` - Token transfers
  - `blockscout.addresses` - Address balance updates
  - `blockscout.address_coin_balances` - Address coin balance updates
  - `blockscout.address_token_balances` - Address token balance updates
  - `blockscout.address_current_token_balances` - Current token balances
  - `blockscout.block_rewards` - Block rewards
  - `blockscout.internal_transactions` - Internal transactions
  - `blockscout.last_block_number` - Latest block number updates
  - `blockscout.token_total_supply` - Token total supply updates
  - `blockscout.contract_verification` - Smart contract verification results
  - `blockscout.changed_bytecode` - Contract bytecode changes
  - `blockscout.raw_traces` - Transaction raw traces
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Explorer.Chain.Block.Reward
  alias Explorer.Chain.Events.Subscriber
  alias Explorer.Chain.Transaction
  alias Explorer.Market
  alias Explorer.Prometheus.Instrumenter
  alias Explorer.Repo

  @nats_prefix "blockscout."

  # JetStream stream configurations for topics that need replay on API server startup
  # These retain recent messages so new subscribers can populate their cache
  @jetstream_streams [
    %{
      name: "BLOCKSCOUT_BLOCKS",
      subjects: ["blockscout.blocks"],
      max_msgs: 50,
      # 1 hour in seconds
      max_age: 3600
    },
    %{
      name: "BLOCKSCOUT_TRANSACTIONS",
      subjects: ["blockscout.transactions"],
      max_msgs: 100,
      max_age: 3600
    },
    %{
      name: "BLOCKSCOUT_PENDING",
      subjects: ["blockscout.pending_transactions"],
      max_msgs: 5000,
      # 30 minutes
      max_age: 1800
    },
    %{
      name: "BLOCKSCOUT_EXCHANGE_RATE",
      subjects: ["blockscout.exchange_rate"],
      # Only latest value
      max_msgs: 1,
      # 24 hours
      max_age: 86400
    },
    %{
      name: "BLOCKSCOUT_TX_STATS",
      subjects: ["blockscout.transaction_stats"],
      # Only latest value
      max_msgs: 1,
      max_age: 86400
    }
  ]

  # Topics that use JetStream (need replay capability)
  @jetstream_topics ~w(blocks transactions pending_transactions exchange_rate transaction_stats)

  # Broadcast events (with type) to subscribe to and publish
  # Some events have both :realtime and :on_demand types
  @subscribed_broadcast_events [
    # Realtime events
    {:blocks, :realtime},
    {:transactions, :realtime},
    {:token_transfers, :realtime},
    {:addresses, :realtime},
    {:address_coin_balances, :realtime},
    {:address_token_balances, :realtime},
    {:block_rewards, :realtime},
    {:internal_transactions, :realtime},
    {:last_block_number, :realtime},
    # On-demand events
    {:addresses, :on_demand},
    {:address_coin_balances, :on_demand},
    {:address_token_balances, :on_demand},
    {:internal_transactions, :on_demand},
    {:contract_verification_result, :on_demand},
    {:smart_contract_was_verified, :on_demand},
    {:smart_contract_was_not_verified, :on_demand},
    {:eth_bytecode_db_lookup_started, :on_demand},
    {:token_total_supply, :on_demand},
    {:changed_bytecode, :on_demand},
    {:address_current_token_balances, :on_demand}
  ]

  # Simple events (no type)
  @subscribed_simple_events [
    :exchange_rate,
    :transaction_stats
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    nats_url = Keyword.get(opts, :nats_url) || Application.get_env(:explorer, :nats_url)

    if nats_url do
      Logger.info("[Nats.Publisher] Starting with NATS URL: #{nats_url}")

      # Parse NATS URL
      uri = URI.parse(nats_url)
      host = uri.host || "localhost"
      port = uri.port || 4222

      # Subscribe to broadcast events (with type)
      Enum.each(@subscribed_broadcast_events, fn {event, type} ->
        Subscriber.to(event, type)
      end)

      # Subscribe to simple events (no type)
      Enum.each(@subscribed_simple_events, fn event ->
        Subscriber.to(event)
      end)

      # Start NATS connection
      case start_nats_connection(host, port) do
        {:ok, conn} ->
          Logger.info("[Nats.Publisher] Connected to NATS at #{host}:#{port}")
          Instrumenter.nats_publisher_connected(true)
          # Create JetStream streams for topics that need replay (non-fatal if fails)
          try do
            setup_jetstream_streams(conn)
          rescue
            e ->
              Logger.warning("[Nats.Publisher] JetStream setup failed (non-fatal): #{inspect(e)}")
          catch
            :exit, reason ->
              Logger.warning("[Nats.Publisher] JetStream setup exited (non-fatal): #{inspect(reason)}")
          end

          {:ok, %{conn: conn, connected: true}}

        {:error, reason} ->
          Logger.warning("[Nats.Publisher] Failed to connect to NATS: #{inspect(reason)}, will retry")
          Instrumenter.nats_publisher_connected(false)
          schedule_reconnect()
          {:ok, %{conn: nil, connected: false, host: host, port: port}}
      end
    else
      Logger.info("[Nats.Publisher] NATS URL not configured, publisher disabled")
      :ignore
    end
  end

  @impl GenServer
  # ===================
  # Realtime Events
  # ===================

  def handle_info({:chain_event, :blocks, :realtime, blocks}, state) do
    publish_event(state, "blocks", serialize_blocks(blocks))
    {:noreply, state}
  end

  def handle_info({:chain_event, :transactions, :realtime, transactions}, state) do
    # Separate pending (mempool) from confirmed transactions
    {pending, confirmed} = Enum.split_with(transactions, fn tx -> is_nil(tx.block_number) end)

    if length(pending) > 0 do
      publish_event(state, "pending_transactions", serialize_transactions(pending))
    end

    if length(confirmed) > 0 do
      publish_event(state, "transactions", serialize_transactions(confirmed))
    end

    {:noreply, state}
  end

  def handle_info({:chain_event, :token_transfers, :realtime, transfers}, state) do
    publish_event(state, "token_transfers", serialize_token_transfers(transfers))
    {:noreply, state}
  end

  def handle_info({:chain_event, :addresses, :realtime, addresses}, state) do
    publish_event(state, "addresses", serialize_addresses(addresses))
    {:noreply, state}
  end

  def handle_info({:chain_event, :address_coin_balances, :realtime, balances}, state) do
    publish_event(state, "address_coin_balances", serialize_address_coin_balances(balances))
    {:noreply, state}
  end

  def handle_info({:chain_event, :address_token_balances, :realtime, balances}, state) do
    publish_event(state, "address_token_balances", serialize_address_token_balances(balances))
    {:noreply, state}
  end

  def handle_info({:chain_event, :block_rewards, :realtime, rewards}, state) do
    publish_event(state, "block_rewards", serialize_block_rewards(rewards))
    {:noreply, state}
  end

  def handle_info({:chain_event, :internal_transactions, :realtime, internal_txs}, state) do
    publish_event(state, "internal_transactions", serialize_internal_transactions(internal_txs))

    # Also publish raw_trace events for first traces (index 0) - used by transaction detail pages
    first_traces = Enum.filter(internal_txs, fn itx -> itx.index == 0 end)

    if length(first_traces) > 0 do
      raw_trace_events =
        Enum.map(first_traces, fn itx ->
          %{transaction_hash: to_string(itx.transaction_hash)}
        end)

      publish_event(state, "raw_traces", raw_trace_events)
    end

    {:noreply, state}
  end

  def handle_info({:chain_event, :last_block_number, :realtime, block_number}, state) do
    publish_event(state, "last_block_number", %{block_number: block_number})
    {:noreply, state}
  end

  # ===================
  # On-Demand Events
  # ===================

  # On-demand versions of realtime events (for specific address/tx lookups)
  def handle_info({:chain_event, :addresses, :on_demand, addresses}, state) do
    publish_event(state, "addresses", serialize_addresses(addresses))
    {:noreply, state}
  end

  def handle_info({:chain_event, :address_coin_balances, :on_demand, balances}, state) do
    publish_event(state, "address_coin_balances", serialize_address_coin_balances(balances))
    {:noreply, state}
  end

  def handle_info({:chain_event, :address_token_balances, :on_demand, balances}, state) do
    publish_event(state, "address_token_balances", serialize_address_token_balances(balances))
    {:noreply, state}
  end

  def handle_info({:chain_event, :internal_transactions, :on_demand, internal_txs}, state) do
    publish_event(state, "internal_transactions", serialize_internal_transactions(internal_txs))

    # Also publish raw_trace events for first traces (index 0)
    first_traces = Enum.filter(internal_txs, fn itx -> itx.index == 0 end)

    if length(first_traces) > 0 do
      raw_trace_events =
        Enum.map(first_traces, fn itx ->
          %{transaction_hash: to_string(itx.transaction_hash)}
        end)

      publish_event(state, "raw_traces", raw_trace_events)
    end

    {:noreply, state}
  end

  # Contract verification result (API v2 format - no conn)
  def handle_info({:chain_event, :contract_verification_result, :on_demand, {address_hash, result}}, state) do
    publish_event(state, "contract_verification", serialize_verification_result(address_hash, result))
    {:noreply, state}
  end

  # Contract verification result (legacy format - with conn, ignore conn)
  def handle_info({:chain_event, :contract_verification_result, :on_demand, {address_hash, result, _conn}}, state) do
    publish_event(state, "contract_verification", serialize_verification_result(address_hash, result))
    {:noreply, state}
  end

  # Smart contract was verified via eth_bytecode_db lookup
  def handle_info({:chain_event, :smart_contract_was_verified, :on_demand, address_hashes}, state) do
    data = Enum.map(List.wrap(address_hashes), fn hash -> %{address_hash: to_string(hash), event: "verified"} end)
    publish_event(state, "contract_verification", data)
    {:noreply, state}
  end

  # Smart contract verification failed
  def handle_info({:chain_event, :smart_contract_was_not_verified, :on_demand, address_hashes}, state) do
    data = Enum.map(List.wrap(address_hashes), fn hash -> %{address_hash: to_string(hash), event: "not_verified"} end)
    publish_event(state, "contract_verification", data)
    {:noreply, state}
  end

  # Bytecode DB lookup started
  def handle_info({:chain_event, :eth_bytecode_db_lookup_started, :on_demand, address_hashes}, state) do
    data = Enum.map(List.wrap(address_hashes), fn hash -> %{address_hash: to_string(hash), event: "lookup_started"} end)
    publish_event(state, "contract_verification", data)
    {:noreply, state}
  end

  # Token total supply updated
  def handle_info({:chain_event, :token_total_supply, :on_demand, tokens}, state) do
    publish_event(state, "token_total_supply", serialize_token_total_supply(tokens))
    {:noreply, state}
  end

  # Contract bytecode changed
  def handle_info({:chain_event, :changed_bytecode, :on_demand, address_hashes}, state) do
    data = Enum.map(List.wrap(address_hashes), fn hash -> %{address_hash: to_string(hash)} end)
    publish_event(state, "changed_bytecode", data)
    {:noreply, state}
  end

  # Current token balances for an address
  def handle_info({:chain_event, :address_current_token_balances, :on_demand, data}, state) do
    publish_event(state, "address_current_token_balances", serialize_current_token_balances(data))
    {:noreply, state}
  end

  # ===================
  # Simple Events (no type)
  # ===================

  def handle_info({:chain_event, :exchange_rate}, state) do
    # Fetch current exchange rate and publish
    exchange_rate = Market.get_coin_exchange_rate()
    publish_event(state, "exchange_rate", serialize_exchange_rate(exchange_rate))
    {:noreply, state}
  end

  def handle_info({:chain_event, :transaction_stats}, state) do
    # Signal that transaction stats have been updated
    publish_event(state, "transaction_stats", %{updated: true})
    {:noreply, state}
  end

  def handle_info(:reconnect, %{host: host, port: port} = state) do
    case start_nats_connection(host, port) do
      {:ok, conn} ->
        Logger.info("[Nats.Publisher] Reconnected to NATS")
        Instrumenter.nats_publisher_connected(true)
        {:noreply, %{state | conn: conn, connected: true}}

      {:error, _reason} ->
        schedule_reconnect()
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.warning("[Nats.Publisher] NATS connection lost: #{inspect(reason)}")
    Instrumenter.nats_publisher_connected(false)
    schedule_reconnect()
    {:noreply, %{state | conn: nil, connected: false}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp start_nats_connection(host, port) do
    Gnat.start_link(%{host: host, port: port})
  end

  defp schedule_reconnect do
    Process.send_after(self(), :reconnect, 5_000)
  end

  defp setup_jetstream_streams(conn) do
    Enum.each(@jetstream_streams, fn stream_config ->
      stream = %Gnat.Jetstream.API.Stream{
        name: stream_config.name,
        subjects: stream_config.subjects,
        retention: :limits,
        max_msgs: stream_config.max_msgs,
        # Convert to nanoseconds
        max_age: stream_config.max_age * 1_000_000_000,
        # Use memory storage for speed
        storage: :memory,
        # Discard old messages when limits reached
        discard: :old
      }

      case Gnat.Jetstream.API.Stream.create(conn, stream) do
        {:ok, _info} ->
          Logger.info("[Nats.Publisher] Created/verified JetStream stream: #{stream_config.name}")

        {:error, %{"err_code" => 10058}} ->
          # Stream already exists, update it
          case Gnat.Jetstream.API.Stream.update(conn, stream) do
            {:ok, _} ->
              Logger.debug("[Nats.Publisher] Updated JetStream stream: #{stream_config.name}")

            {:error, reason} ->
              Logger.warning("[Nats.Publisher] Failed to update stream #{stream_config.name}: #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.warning("[Nats.Publisher] Failed to create JetStream stream #{stream_config.name}: #{inspect(reason)}")
      end
    end)
  end

  defp publish_event(%{connected: false}, topic, data) do
    # Log dropped events so we have visibility when NATS is disconnected
    event_count =
      case data do
        list when is_list(list) -> length(list)
        _ -> 1
      end

    Logger.warning("[Nats.Publisher] DROPPING #{event_count} event(s) for topic '#{topic}' - NATS disconnected")

    # Track dropped events in metrics
    Instrumenter.nats_publish_dropped(topic, event_count)

    :ok
  end

  defp publish_event(%{conn: conn}, topic, data) do
    nats_topic = @nats_prefix <> topic
    # Wrap data with timestamp for lag measurement on subscriber side
    # _ts is Unix timestamp in milliseconds
    envelope = %{_ts: System.system_time(:millisecond), d: data}
    payload = Jason.encode!(envelope)
    payload_size = byte_size(payload)
    start_time = System.monotonic_time(:microsecond)

    # Use JetStream for topics that need replay, Core NATS for others
    result =
      if topic in @jetstream_topics do
        case Gnat.pub(conn, nats_topic, payload) do
          :ok ->
            Logger.debug("[Nats.Publisher] Published to JetStream #{nats_topic}")
            :ok

          {:error, reason} ->
            Logger.warning("[Nats.Publisher] Failed to publish to JetStream #{nats_topic}: #{inspect(reason)}")
            {:error, reason}
        end
      else
        case Gnat.pub(conn, nats_topic, payload) do
          :ok ->
            Logger.debug("[Nats.Publisher] Published to #{nats_topic}")
            :ok

          {:error, reason} ->
            Logger.warning("[Nats.Publisher] Failed to publish to #{nats_topic}: #{inspect(reason)}")
            {:error, reason}
        end
      end

    # Record metrics
    duration = (System.monotonic_time(:microsecond) - start_time) / 1_000_000
    Instrumenter.nats_publish(topic, duration, payload_size, result)

    result
  end

  # Serialization functions - convert structs to JSON-friendly maps

  defp serialize_blocks(blocks) do
    # Batch fetch transaction counts and rewards for blocks with unloaded associations
    # This avoids N+1 queries when associations aren't preloaded (which is common for realtime events)
    block_hashes = Enum.map(blocks, & &1.hash)

    # Fetch transaction counts for blocks where transactions aren't loaded
    tx_counts_map = fetch_transaction_counts(blocks, block_hashes)

    # Fetch rewards for blocks where rewards aren't loaded
    rewards_map = fetch_block_rewards(blocks, block_hashes)

    # Fetch miner names for blocks where miner.names isn't loaded
    miner_names_map = fetch_miner_names(blocks)

    Enum.map(blocks, fn block ->
      # Get transaction count - prefer loaded association, fall back to queried count
      tx_count =
        case loaded_list_length(block.transactions) do
          nil -> Map.get(tx_counts_map, block.hash, 0)
          count -> count
        end

      gas_used = decimal_value(block.gas_used)
      gas_limit = decimal_value(block.gas_limit)

      # Calculate percentages
      gas_used_percentage =
        if gas_limit && Decimal.compare(gas_limit, 0) == :gt do
          gas_used |> Decimal.div(gas_limit) |> Decimal.mult(100) |> Decimal.to_float()
        else
          0.0
        end

      elasticity_multiplier = Application.get_env(:explorer, :elasticity_multiplier) || 2

      gas_target_percentage =
        if gas_limit && Decimal.compare(gas_limit, 0) == :gt do
          ratio = Decimal.div(gas_used, Decimal.div(gas_limit, elasticity_multiplier))
          ratio |> Decimal.sub(1) |> Decimal.mult(100) |> Decimal.to_float()
        else
          0.0
        end

      # Calculate fees from transactions if loaded
      {tx_fees, burnt_fees, priority_fee} = calculate_block_fees(block)

      burnt_fees_percentage =
        if tx_fees && burnt_fees && Decimal.compare(tx_fees, 0) == :gt do
          burnt_fees |> Decimal.div(tx_fees) |> Decimal.mult(100) |> Decimal.to_float()
        else
          nil
        end

      %{
        # Core fields matching API v2 BlockView format exactly
        height: block.number,
        hash: to_string(block.hash),
        parent_hash: to_string(block.parent_hash),
        timestamp: DateTime.to_iso8601(block.timestamp),
        size: block.size,
        gas_used: to_string(block.gas_used),
        gas_limit: to_string(block.gas_limit),
        # Must match frontend Block type
        transaction_count: tx_count,
        type: block_type(block),

        # Miner as AddressParam object
        miner: serialize_miner(block, miner_names_map),

        # Additional fields the frontend expects
        difficulty: to_string(block.difficulty || 0),
        total_difficulty: to_string(block.total_difficulty || 0),
        nonce: to_string(block.nonce || "0x0000000000000000"),
        base_fee_per_gas: if(block.base_fee_per_gas, do: to_string(block.base_fee_per_gas.value)),
        extra_data: nil,
        state_root: nil,

        # Fee calculations - use exact frontend field names
        transaction_fees: if(tx_fees, do: to_string(tx_fees)),
        burnt_fees: if(burnt_fees, do: to_string(burnt_fees)),
        priority_fee: if(priority_fee, do: to_string(priority_fee)),

        # Percentages
        gas_used_percentage: gas_used_percentage,
        gas_target_percentage: gas_target_percentage,
        burnt_fees_percentage: burnt_fees_percentage,

        # Rewards - prefer loaded association, fall back to queried rewards
        rewards:
          case Ecto.assoc_loaded?(block.rewards) and is_list(block.rewards) do
            true -> serialize_block_rewards_inline(block)
            false -> Map.get(rewards_map, block.hash, [])
          end,

        # Other fields
        uncles_hashes: [],
        withdrawals_count: nil
      }
    end)
  end

  # Serialize miner as AddressParam format for frontend
  # Note: miner association may not be loaded - check with Ecto.assoc_loaded?
  # miner_names_map provides fallback names for miners whose names weren't preloaded
  defp serialize_miner(block, miner_names_map) do
    miner_hash = to_string(block.miner_hash)
    miner = block.miner

    # Check if miner association is actually loaded (not NotLoaded struct)
    miner_loaded? = Ecto.assoc_loaded?(miner)

    if miner_loaded? and not is_nil(miner) do
      # Try to get name from loaded association first, fall back to queried map
      name =
        case get_address_name(miner) do
          nil -> Map.get(miner_names_map, block.miner_hash)
          name -> name
        end

      %{
        hash: miner_hash,
        name: name,
        is_contract: not is_nil(miner.contract_code),
        is_verified: nil,
        implementations: nil,
        ens_domain_name: nil,
        private_tags: nil,
        watchlist_names: nil,
        public_tags: nil
      }
    else
      # Miner not loaded - use queried name from map
      %{
        hash: miner_hash,
        name: Map.get(miner_names_map, block.miner_hash),
        is_contract: false,
        is_verified: nil,
        implementations: nil,
        ens_domain_name: nil,
        private_tags: nil,
        watchlist_names: nil,
        public_tags: nil
      }
    end
  end

  # Get address name from names association (same logic as BlockScoutWeb.API.V2.Helper.address_name)
  defp get_address_name(%{names: names}) when is_list(names) and length(names) > 0 do
    case Enum.find(names, &(&1.primary == true)) do
      nil ->
        %Explorer.Chain.Address.Name{name: name} = Enum.at(names, 0)
        name

      %Explorer.Chain.Address.Name{name: name} ->
        name
    end
  end

  defp get_address_name(_), do: nil

  # Calculate fees from loaded transactions
  defp calculate_block_fees(%{transactions: txs, base_fee_per_gas: base_fee})
       when is_list(txs) and not is_nil(base_fee) do
    tx_fees =
      Enum.reduce(txs, Decimal.new(0), fn tx, acc ->
        fee = calculate_tx_fee(tx)
        Decimal.add(acc, fee || Decimal.new(0))
      end)

    burnt_fees =
      Enum.reduce(txs, Decimal.new(0), fn tx, acc ->
        burnt = calculate_burnt_fee(tx, base_fee)
        Decimal.add(acc, burnt || Decimal.new(0))
      end)

    priority_fee = Decimal.sub(tx_fees, burnt_fees)
    {tx_fees, burnt_fees, priority_fee}
  end

  defp calculate_block_fees(_), do: {nil, nil, nil}

  defp calculate_tx_fee(%{gas_used: gas_used, gas_price: gas_price})
       when not is_nil(gas_used) and not is_nil(gas_price) do
    Decimal.mult(decimal_value(gas_used), gas_price.value)
  end

  defp calculate_tx_fee(_), do: nil

  defp calculate_burnt_fee(%{gas_used: gas_used}, base_fee) when not is_nil(gas_used) and not is_nil(base_fee) do
    Decimal.mult(decimal_value(gas_used), base_fee.value)
  end

  defp calculate_burnt_fee(_, _), do: Decimal.new(0)

  defp decimal_value(%Decimal{} = d), do: d
  defp decimal_value(n) when is_integer(n), do: Decimal.new(n)
  defp decimal_value(_), do: Decimal.new(0)

  # Serialize rewards inline from block
  defp serialize_block_rewards_inline(%{rewards: rewards}) when is_list(rewards) do
    Enum.map(rewards, fn reward ->
      %{
        reward: to_string(reward.reward.value),
        type: to_string(reward.address_type)
      }
    end)
  end

  defp serialize_block_rewards_inline(_), do: []

  # Determine block type based on consensus field (matches BlockView.block_type/1)
  defp block_type(%{consensus: true}), do: "block"
  defp block_type(%{consensus: false}), do: "reorg"
  defp block_type(_), do: "block"

  # Helper to safely get length of a potentially unloaded association
  defp loaded_list_length(%Ecto.Association.NotLoaded{}), do: nil
  defp loaded_list_length(list) when is_list(list), do: length(list)
  defp loaded_list_length(_), do: nil

  # Fetch transaction counts for blocks where the association isn't loaded
  # Returns a map of block_hash => count
  defp fetch_transaction_counts(blocks, block_hashes) do
    # Only query if there are blocks with unloaded transactions
    needs_fetch =
      Enum.any?(blocks, fn block ->
        not Ecto.assoc_loaded?(block.transactions)
      end)

    if needs_fetch and length(block_hashes) > 0 do
      query =
        from(t in Transaction,
          where: t.block_hash in ^block_hashes,
          group_by: t.block_hash,
          select: {t.block_hash, count(t.hash)}
        )

      query
      |> Repo.all()
      |> Map.new()
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  # Fetch block rewards for blocks where the association isn't loaded
  # Returns a map of block_hash => [%{reward: string, type: string}]
  defp fetch_block_rewards(blocks, block_hashes) do
    # Only query if there are blocks with unloaded rewards
    needs_fetch =
      Enum.any?(blocks, fn block ->
        not Ecto.assoc_loaded?(block.rewards)
      end)

    if needs_fetch and length(block_hashes) > 0 do
      query =
        from(r in Reward,
          where: r.block_hash in ^block_hashes,
          select: {r.block_hash, r.address_type, r.reward}
        )

      query
      |> Repo.all()
      |> Enum.group_by(
        fn {block_hash, _type, _reward} -> block_hash end,
        fn {_block_hash, address_type, reward} ->
          # Format reward to match frontend Reward type
          # Frontend expects: { reward: string, type: 'Validator Reward' | 'Miner Reward' | ... }
          %{
            reward: to_string(reward.value),
            type: format_reward_type(address_type)
          }
        end
      )
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  # Fetch miner names for blocks where miner.names isn't loaded
  # Returns a map of miner_hash => name (string)
  defp fetch_miner_names(blocks) do
    # Collect miner hashes where names need to be fetched
    # We need to fetch if: miner isn't loaded, or miner.names isn't loaded
    miner_hashes =
      blocks
      |> Enum.map(fn block ->
        miner = block.miner
        miner_loaded? = Ecto.assoc_loaded?(miner)

        cond do
          not miner_loaded? ->
            # Miner not loaded - we need to fetch the name
            block.miner_hash

          is_nil(miner) ->
            # Miner is nil
            nil

          not Ecto.assoc_loaded?(miner.names) ->
            # Miner loaded but names not loaded
            block.miner_hash

          true ->
            # Both miner and names are loaded
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if length(miner_hashes) > 0 do
      # Query address_names for the miner addresses
      query =
        from(n in Explorer.Chain.Address.Name,
          where: n.address_hash in ^miner_hashes,
          select: {n.address_hash, n.name, n.primary}
        )

      query
      |> Repo.all()
      |> Enum.group_by(fn {hash, _name, _primary} -> hash end)
      |> Enum.map(fn {hash, names} ->
        # Pick primary name first, otherwise first name
        name =
          case Enum.find(names, fn {_h, _n, primary} -> primary == true end) do
            nil ->
              {_h, name, _p} = Enum.at(names, 0)
              name

            {_h, name, _p} ->
              name
          end

        {hash, name}
      end)
      |> Map.new()
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  # Format reward type to match frontend's expected values
  # Frontend Reward type expects: 'Miner Reward' | 'Validator Reward' | 'Emission Reward' | ...
  defp format_reward_type(:validator), do: "Validator Reward"
  defp format_reward_type(:emission_funds), do: "Emission Reward"
  defp format_reward_type(:uncle), do: "Uncle Reward"
  defp format_reward_type(:poa_mania), do: "POA Mania Reward"
  defp format_reward_type(:chore), do: "Chore Reward"
  defp format_reward_type(_), do: "Miner Reward"

  defp serialize_transactions(transactions) do
    Enum.map(transactions, fn tx ->
      %{
        hash: to_string(tx.hash),
        block_number: tx.block_number,
        from_address_hash: to_string(tx.from_address_hash),
        to_address_hash: if(tx.to_address_hash, do: to_string(tx.to_address_hash)),
        value: to_string(tx.value.value),
        gas: tx.gas,
        gas_price: if(tx.gas_price, do: to_string(tx.gas_price.value)),
        status: tx.status
      }
    end)
  end

  defp serialize_token_transfers(transfers) do
    Enum.map(transfers, fn tt ->
      %{
        transaction_hash: to_string(tt.transaction_hash),
        log_index: tt.log_index,
        from_address_hash: to_string(tt.from_address_hash),
        to_address_hash: to_string(tt.to_address_hash),
        token_contract_address_hash: to_string(tt.token_contract_address_hash),
        amount: if(tt.amount, do: to_string(tt.amount)),
        token_id: if(tt.token_id, do: to_string(tt.token_id))
      }
    end)
  end

  defp serialize_addresses(addresses) do
    Enum.map(addresses, fn addr ->
      %{
        hash: to_string(addr.hash),
        fetched_coin_balance: if(addr.fetched_coin_balance, do: to_string(addr.fetched_coin_balance.value)),
        fetched_coin_balance_block_number: addr.fetched_coin_balance_block_number
      }
    end)
  end

  defp serialize_address_coin_balances(balances) do
    Enum.map(balances, fn balance ->
      %{
        address_hash: to_string(balance.address_hash),
        block_number: balance.block_number
      }
    end)
  end

  defp serialize_address_token_balances(balances) do
    Enum.map(balances, fn balance ->
      %{
        address_hash: to_string(balance.address_hash),
        block_number: balance.block_number
      }
    end)
  end

  defp serialize_block_rewards(rewards) do
    Enum.map(rewards, fn reward ->
      %{
        address_hash: to_string(reward.address_hash),
        block_hash: to_string(reward.block_hash),
        address_type: reward.address_type,
        reward: if(reward.reward, do: to_string(reward.reward.value))
      }
    end)
  end

  defp serialize_internal_transactions(internal_txs) do
    Enum.map(internal_txs, fn itx ->
      %{
        transaction_hash: to_string(itx.transaction_hash),
        index: itx.index,
        from_address_hash: to_string(itx.from_address_hash),
        to_address_hash: if(itx.to_address_hash, do: to_string(itx.to_address_hash)),
        value: if(itx.value, do: to_string(itx.value.value)),
        type: itx.type,
        call_type: itx.call_type,
        gas: itx.gas,
        gas_used: itx.gas_used
      }
    end)
  end

  defp serialize_token_total_supply(tokens) do
    tokens
    |> List.wrap()
    |> Enum.map(fn token ->
      %{
        contract_address_hash: to_string(token.contract_address_hash),
        total_supply: if(token.total_supply, do: to_string(token.total_supply))
      }
    end)
  end

  defp serialize_current_token_balances(data) do
    %{
      address_hash: to_string(data.address_hash),
      token_balances:
        Enum.map(data.address_current_token_balances, fn balance ->
          %{
            token_contract_address_hash: to_string(balance.token_contract_address_hash),
            value: if(balance.value, do: to_string(balance.value)),
            token_id: if(balance.token_id, do: to_string(balance.token_id))
          }
        end)
    }
  end

  defp serialize_exchange_rate(exchange_rate) do
    %{
      usd_value: if(exchange_rate.usd_value, do: to_string(exchange_rate.usd_value)),
      btc_value: if(exchange_rate.btc_value, do: to_string(exchange_rate.btc_value)),
      market_cap_usd: if(exchange_rate.market_cap_usd, do: to_string(exchange_rate.market_cap_usd)),
      available_supply: if(exchange_rate.available_supply, do: to_string(exchange_rate.available_supply))
    }
  end

  defp serialize_verification_result(address_hash, {:ok, %{address_hash: _} = smart_contract}) do
    %{
      address_hash: to_string(address_hash),
      status: "success",
      contract_name: Map.get(smart_contract, :name),
      compiler_version: Map.get(smart_contract, :compiler_version),
      optimization: Map.get(smart_contract, :optimization),
      evm_version: Map.get(smart_contract, :evm_version)
    }
  end

  defp serialize_verification_result(address_hash, {:error, changeset}) do
    errors =
      case changeset do
        %Ecto.Changeset{} = cs ->
          Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)

        other ->
          %{error: inspect(other)}
      end

    %{
      address_hash: to_string(address_hash),
      status: "error",
      errors: errors
    }
  end

  defp serialize_verification_result(address_hash, result) do
    %{
      address_hash: to_string(address_hash),
      status: if(match?({:ok, _}, result), do: "success", else: "error"),
      result: inspect(result)
    }
  end
end
