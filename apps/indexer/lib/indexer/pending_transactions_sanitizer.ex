defmodule Indexer.PendingTransactionsSanitizer do
  @moduledoc """
  Periodically checks pending transactions status in order to detect that transaction already included to the block
  And we need to re-fetch that block.

  ## Strategy

  1. Delete stale pending transactions (older than 3 hours) without RPC check - they're definitely
     either confirmed or dropped by now
  2. Check recent pending transactions (< 3 hours) via RPC to see if they've been confirmed
  3. Run every 15 minutes to keep the pending transaction pool clean
  """

  use GenServer

  require Logger

  import Ecto.Query
  import EthereumJSONRPC, only: [json_rpc: 2, request: 1]
  import EthereumJSONRPC.Receipt, only: [to_elixir: 1]

  alias Ecto.Changeset
  alias Explorer.{Chain, Repo}
  alias Explorer.Chain.Hash.Full, as: Hash
  alias Explorer.Chain.Import.Runner.Blocks
  alias Explorer.Chain.Transaction
  alias Explorer.Chain.Wei

  # Run every 15 minutes
  @interval :timer.minutes(15)

  # Delete pending transactions older than this without RPC check
  @stale_threshold_hours 3

  defstruct interval: @interval,
            json_rpc_named_arguments: []

  def child_spec([init_arguments]) do
    child_spec([init_arguments, []])
  end

  def child_spec([_init_arguments, _gen_server_options] = start_link_arguments) do
    default = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, start_link_arguments}
    }

    Supervisor.child_spec(default, [])
  end

  def start_link(init_opts, gen_server_opts \\ []) do
    GenServer.start_link(__MODULE__, init_opts, gen_server_opts)
  end

  def init(opts) when is_list(opts) do
    state = %__MODULE__{
      json_rpc_named_arguments: Keyword.fetch!(opts, :json_rpc_named_arguments),
      interval: opts[:interval] || @interval
    }

    Process.send_after(self(), :sanitize_pending_transactions, state.interval)

    {:ok, state}
  end

  def handle_info(
        :sanitize_pending_transactions,
        %{interval: interval, json_rpc_named_arguments: json_rpc_named_arguments} = state
      ) do
    Logger.info("[PendingTxSanitizer] Starting pending transaction cleanup")

    # Step 1: Delete stale pending transactions (> 3 hours old) without RPC check
    stale_deleted = delete_stale_pending_transactions()
    Logger.info("[PendingTxSanitizer] Deleted #{stale_deleted} stale pending transactions (> #{@stale_threshold_hours}h old)")

    # Step 2: Check recent pending transactions via RPC
    sanitize_recent_pending_transactions(json_rpc_named_arguments)

    Process.send_after(self(), :sanitize_pending_transactions, interval)

    {:noreply, state}
  end

  # Delete pending transactions older than @stale_threshold_hours without checking RPC
  # These are definitely either confirmed or dropped by now
  defp delete_stale_pending_transactions do
    stale_cutoff = DateTime.utc_now() |> DateTime.add(-@stale_threshold_hours * 3600, :second)

    {deleted_count, _} =
      from(t in Transaction,
        where: is_nil(t.block_hash),
        where: t.inserted_at < ^stale_cutoff
      )
      |> Repo.delete_all(timeout: :infinity)

    deleted_count
  end

  # Check recent pending transactions via RPC with a limit
  defp sanitize_recent_pending_transactions(json_rpc_named_arguments) do
    recent_pending = get_recent_pending_transactions()
    count = length(recent_pending)

    Logger.info("[PendingTxSanitizer] Checking #{count} recent pending transactions via RPC")

    recent_pending
    |> Enum.with_index()
    |> Enum.each(fn {pending_tx, ind} ->
      pending_tx_hash_str = "0x" <> Base.encode16(pending_tx.hash.bytes, case: :lower)

      with {:ok, result} <-
             %{id: ind, method: "eth_getTransactionReceipt", params: [pending_tx_hash_str]}
             |> request()
             |> json_rpc(json_rpc_named_arguments) do
        if result do
          fetch_block_and_invalidate_wrapper(pending_tx, pending_tx_hash_str, result)
        else
          Logger.debug(
            "[PendingTxSanitizer] Transaction #{pending_tx_hash_str} not found in node, deleting",
            fetcher: :pending_transactions_to_refetch
          )

          delete_pending_transaction(pending_tx)
        end
      end
    end)

    Logger.info("[PendingTxSanitizer] Finished checking recent pending transactions")
  end

  # Get recent pending transactions (< @stale_threshold_hours old)
  defp get_recent_pending_transactions do
    stale_cutoff = DateTime.utc_now() |> DateTime.add(-@stale_threshold_hours * 3600, :second)

    from(t in Transaction,
      where: is_nil(t.block_hash),
      where: t.inserted_at >= ^stale_cutoff,
      where: is_nil(t.error) or t.error != "dropped/replaced",
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all(timeout: :infinity)
  end

  defp fetch_block_and_invalidate_wrapper(pending_tx, pending_tx_hash_str, result) do
    block_hash = Map.get(result, "blockHash")

    if block_hash do
      Logger.debug(
        "[PendingTxSanitizer] Transaction #{pending_tx_hash_str} confirmed in block #{block_hash}",
        fetcher: :pending_transactions_to_refetch
      )

      fetch_block_and_invalidate(block_hash, pending_tx, result)
    else
      Logger.debug(
        "[PendingTxSanitizer] Transaction #{pending_tx_hash_str} still pending",
        fetcher: :pending_transactions_to_refetch
      )
    end
  end

  defp delete_pending_transaction(transaction) do
    pending_tx_hash_str = "0x" <> Base.encode16(transaction.hash.bytes, case: :lower)

    case transaction
         |> Changeset.change()
         |> Repo.delete() do
      {:ok, _transaction} ->
        Logger.debug(
          "[PendingTxSanitizer] Deleted #{pending_tx_hash_str}",
          fetcher: :pending_transactions_to_refetch
        )

      {:error, changeset} ->
        Logger.warning(
          "[PendingTxSanitizer] Failed to delete #{pending_tx_hash_str}: #{inspect(changeset)}",
          fetcher: :pending_transactions_to_refetch
        )
    end
  end

  defp fetch_block_and_invalidate(block_hash, pending_tx, tx) do
    case Chain.fetch_block_by_hash(block_hash) do
      %{number: number, consensus: consensus} ->
        Logger.debug(
          "[PendingTxSanitizer] Block #{block_hash} found: number=#{number}, consensus=#{consensus}",
          fetcher: :pending_transactions_to_refetch
        )

        invalidate_block(number, block_hash, consensus, pending_tx, tx)

      _ ->
        Logger.debug(
          "[PendingTxSanitizer] Block #{block_hash} not yet in DB",
          fetcher: :pending_transactions_to_refetch
        )
    end
  end

  defp invalidate_block(block_number, block_hash, consensus, pending_tx, tx) do
    if consensus do
      Blocks.invalidate_consensus_blocks([block_number])
    else
      {:ok, hash} = Hash.cast(block_hash)
      tx_info = to_elixir(tx)

      # Get gas_price from receipt's effectiveGasPrice or fall back to pending tx's gas_price
      # This is required because the collated_gas_price constraint requires gas_price when block_hash is set
      gas_price = get_gas_price(tx_info, pending_tx)

      changeset =
        pending_tx
        |> Transaction.changeset()
        |> Changeset.put_change(:cumulative_gas_used, tx_info["cumulativeGasUsed"])
        |> Changeset.put_change(:gas_used, tx_info["gasUsed"])
        |> Changeset.put_change(:index, tx_info["transactionIndex"])
        |> Changeset.put_change(:block_number, block_number)
        |> Changeset.put_change(:block_hash, hash)
        |> maybe_put_gas_price(gas_price)

      Repo.update(changeset)

      Logger.debug(
        "[PendingTxSanitizer] Assigned pending tx to block ##{block_number}"
      )
    end
  end

  # Get gas_price from receipt's effectiveGasPrice (for EIP-1559 txs) or use existing gas_price
  defp get_gas_price(tx_info, pending_tx) do
    case tx_info["effectiveGasPrice"] do
      nil ->
        # Fall back to pending transaction's gas_price
        pending_tx.gas_price

      effective_gas_price when is_binary(effective_gas_price) ->
        # Parse hex string and wrap in Wei struct
        {value, _} = Integer.parse(String.replace_leading(effective_gas_price, "0x", ""), 16)
        %Wei{value: Decimal.new(value)}

      effective_gas_price when is_integer(effective_gas_price) ->
        %Wei{value: Decimal.new(effective_gas_price)}

      _ ->
        pending_tx.gas_price
    end
  end

  defp maybe_put_gas_price(changeset, nil), do: changeset
  defp maybe_put_gas_price(changeset, gas_price), do: Changeset.put_change(changeset, :gas_price, gas_price)
end
