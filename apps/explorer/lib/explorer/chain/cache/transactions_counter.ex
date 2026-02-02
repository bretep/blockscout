defmodule Explorer.Chain.Cache.TransactionsCounter do
  @moduledoc """
  Caches the total number of transactions using incremental counting.

  Instead of counting all 2.3B+ transactions on every update, this counter:
  1. Stores a checkpoint (block_number) along with the count
  2. Subscribes to new block events and counts only new transactions
  3. Adds the incremental count to the stored total

  This reduces consolidation time from 30+ minutes to milliseconds.
  Updates in real-time on each new block (indexer only).
  """

  use GenServer

  import Ecto.Query

  alias Explorer.Chain
  alias Explorer.Chain.Events.Subscriber
  alias Explorer.Chain.Transaction
  alias Explorer.Repo

  @counter_type "transactions_counter"
  @checkpoint_type "transactions_counter_checkpoint"

  # Note: enable_consolidation is checked at runtime via enable_consolidation?/0
  # to respect DISABLE_INDEXER environment variable

  @doc """
  Starts a process to update the transaction counter on new blocks.
  """
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    {:ok, %{consolidate?: enable_consolidation?()}, {:continue, :ok}}
  end

  @impl true
  def handle_continue(:ok, %{consolidate?: true} = state) do
    # Subscribe to new block events
    Subscriber.to(:blocks, :realtime)

    # Do initial consolidation
    consolidate()

    {:noreply, state}
  end

  @impl true
  def handle_continue(:ok, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:chain_event, :blocks, :realtime, _blocks}, %{consolidate?: true} = state) do
    # New blocks arrived - update the counter
    consolidate()
    {:noreply, state}
  end

  @impl true
  def handle_info(_, state) do
    {:noreply, state}
  end

  @doc """
  Fetches the cached transaction count.
  """
  def fetch(options \\ []) do
    Chain.get_last_fetched_counter(@counter_type, options)
  end

  @doc """
  Fetches the current checkpoint (last counted block number).
  """
  def fetch_checkpoint(options \\ []) do
    Chain.get_last_fetched_counter(@checkpoint_type, options)
  end

  @doc """
  Consolidates the counter incrementally.

  If no checkpoint exists, does a full accurate count (once).
  Otherwise, counts only transactions since the checkpoint block.
  """
  def consolidate do
    current_count = fetch([]) || Decimal.new(0)
    checkpoint = fetch_checkpoint([]) || Decimal.new(0)
    checkpoint_int = Decimal.to_integer(checkpoint)

    # Get the current max block number
    max_block = get_max_block_number()

    cond do
      # No checkpoint yet - do full accurate count (runs once)
      checkpoint_int == 0 ->
        initialize_counter(max_block)

      # Checkpoint exists and there are new blocks
      max_block > checkpoint_int ->
        increment_counter(current_count, checkpoint_int, max_block)

      # No new blocks since last checkpoint
      true ->
        :ok
    end
  end

  # Initialize counter with full accurate count (runs once, may take a while)
  defp initialize_counter(max_block) when is_integer(max_block) and max_block > 0 do
    require Logger
    Logger.info("TransactionsCounter: Starting init count up to block #{max_block}")

    try do
      # Do a full count for accuracy - this only happens once on first run
      count =
        from(t in Transaction,
          where: t.block_number <= ^max_block,
          select: count(t.hash)
        )
        |> Repo.one(timeout: :infinity) || 0

      Logger.info("TransactionsCounter: Count complete: #{count} transactions")

      # Store both count and checkpoint
      Chain.upsert_last_fetched_counter(%{counter_type: @counter_type, value: count})
      Chain.upsert_last_fetched_counter(%{counter_type: @checkpoint_type, value: max_block})

      Logger.info("TransactionsCounter: Stored counter and checkpoint (block #{max_block})")
      :ok
    rescue
      e ->
        Logger.error("TransactionsCounter: Init failed: #{inspect(e)}")
        :error
    end
  end

  defp initialize_counter(_), do: :ok

  # Increment counter by counting only new blocks (fast)
  defp increment_counter(current_count, checkpoint, max_block) do
    # Count transactions only in blocks after the checkpoint
    incremental_count =
      from(t in Transaction,
        where: t.block_number > ^checkpoint and t.block_number <= ^max_block,
        select: count(t.hash)
      )
      |> Repo.one(timeout: :timer.minutes(5)) || 0

    new_count = Decimal.add(current_count, incremental_count)

    # Update count and checkpoint
    Chain.upsert_last_fetched_counter(%{counter_type: @counter_type, value: new_count})
    Chain.upsert_last_fetched_counter(%{counter_type: @checkpoint_type, value: max_block})

    :ok
  end

  # Get the maximum block number from the blocks table
  defp get_max_block_number do
    from(b in Explorer.Chain.Block,
      where: b.consensus == true,
      select: max(b.number)
    )
    |> Repo.one(timeout: :timer.seconds(30)) || 0
  end

  @doc """
  Returns a boolean that indicates whether consolidation is enabled.
  Checks runtime config to respect DISABLE_INDEXER environment variable.
  """
  def enable_consolidation? do
    Application.get_env(:explorer, __MODULE__, [])[:enable_consolidation] != false
  end
end
