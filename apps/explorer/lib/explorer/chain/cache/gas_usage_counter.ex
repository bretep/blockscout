defmodule Explorer.Chain.Cache.GasUsageCounter do
  @moduledoc """
  Caches total gas usage using incremental counting.

  Instead of summing all gas_used across 2.3B+ transactions on every update, this counter:
  1. Stores a checkpoint (block_number) along with the total
  2. Subscribes to new block events and sums only new gas usage
  3. Adds the incremental sum to the stored total

  This reduces consolidation time from 30+ minutes to milliseconds.
  Updates in real-time on each new block (indexer only).
  """

  use GenServer

  import Ecto.Query

  alias Explorer.Chain
  alias Explorer.Chain.Events.Subscriber
  alias Explorer.Chain.Transaction
  alias Explorer.Repo

  @counter_type "gas_usage_counter"
  @checkpoint_type "gas_usage_counter_checkpoint"

  # Note: enable_consolidation is checked at runtime via enable_consolidation?/0
  # to respect DISABLE_INDEXER environment variable

  @doc """
  Starts a process to update the gas usage counter on new blocks.
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
  Fetches the cached total gas usage.
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
  Returns the total gas usage, or 0 if not yet initialized.
  """
  def total do
    case fetch([]) do
      nil -> 0
      %Decimal{} = val -> Decimal.to_integer(val)
      val when is_integer(val) -> val
      _ -> 0
    end
  end

  @doc """
  Consolidates the counter incrementally.

  If no checkpoint exists, does a full accurate sum (once).
  Otherwise, sums only gas_used since the checkpoint block.
  """
  def consolidate do
    current_total = fetch([]) || Decimal.new(0)
    checkpoint = fetch_checkpoint([]) || Decimal.new(0)
    checkpoint_int = Decimal.to_integer(checkpoint)

    # Get the current max block number
    max_block = get_max_block_number()

    cond do
      # No checkpoint yet - do full accurate sum (runs once)
      checkpoint_int == 0 and max_block > 0 ->
        initialize_counter(max_block)

      # Checkpoint exists and there are new blocks
      max_block > checkpoint_int ->
        increment_counter(current_total, checkpoint_int, max_block)

      # No new blocks since last checkpoint
      true ->
        :ok
    end
  end

  # Initialize counter with full accurate sum (runs once, may take a while)
  defp initialize_counter(max_block) when is_integer(max_block) and max_block > 0 do
    require Logger
    Logger.info("GasUsageCounter: Starting init sum up to block #{max_block}")

    try do
      # Do a full sum for accuracy - this only happens once on first run
      total =
        from(t in Transaction,
          where: t.block_number <= ^max_block,
          select: sum(t.gas_used)
        )
        |> Repo.one(timeout: :infinity) || 0

      Logger.info("GasUsageCounter: Sum complete: #{total} gas used")

      # Store both total and checkpoint
      Chain.upsert_last_fetched_counter(%{counter_type: @counter_type, value: total})
      Chain.upsert_last_fetched_counter(%{counter_type: @checkpoint_type, value: max_block})

      Logger.info("GasUsageCounter: Stored counter and checkpoint (block #{max_block})")
      :ok
    rescue
      e ->
        Logger.error("GasUsageCounter: Init failed: #{inspect(e)}")
        :error
    end
  end

  defp initialize_counter(_), do: :ok

  # Increment counter by summing only new blocks (fast)
  defp increment_counter(current_total, checkpoint, max_block) do
    # Sum gas_used only in blocks after the checkpoint
    incremental_sum =
      from(t in Transaction,
        where: t.block_number > ^checkpoint and t.block_number <= ^max_block,
        select: sum(t.gas_used)
      )
      |> Repo.one(timeout: :timer.minutes(5)) || 0

    new_total = Decimal.add(current_total, incremental_sum || 0)

    # Update total and checkpoint
    Chain.upsert_last_fetched_counter(%{counter_type: @counter_type, value: new_total})
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
