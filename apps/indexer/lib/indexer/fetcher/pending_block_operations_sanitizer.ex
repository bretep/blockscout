defmodule Indexer.Fetcher.PendingBlockOperationsSanitizer do
  @moduledoc """
  Set block_number for pending block operations that have it empty
  """

  use GenServer

  import Ecto.Query

  alias Explorer.Chain.PendingBlockOperation
  alias Explorer.Repo
  alias Indexer.Fetcher.InternalTransaction

  @interval :timer.seconds(1)
  @batch_size 1000
  @timeout :timer.minutes(1)

  def child_spec(start_link_arguments) do
    spec = %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, start_link_arguments},
      restart: :transient,
      type: :worker
    }

    Supervisor.child_spec(spec, [])
  end

  def start_link(_args, gen_server_options \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(gen_server_options, :name, __MODULE__))
  end

  @impl GenServer
  def init(_) do
    Process.send_after(self(), :update_batch, @interval)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:update_batch, state) do
    start_time = System.monotonic_time(:microsecond)

    result = update_batch()

    duration = (System.monotonic_time(:microsecond) - start_time) / 1_000_000
    record_batch_metrics(duration, length(result))

    case result do
      [] ->
        {:stop, :normal, state}

      _ ->
        Process.send_after(self(), :update_batch, @interval)
        {:noreply, state}
    end
  end

  def update_batch do
    cte_query = from(pbo in PendingBlockOperation, where: is_nil(pbo.block_number), limit: @batch_size)

    {_, block_numbers} =
      PendingBlockOperation
      |> with_cte("cte", as: ^cte_query, materialized: false)
      |> join(:inner, [pbo], po in "cte", on: pbo.block_hash == po.block_hash)
      |> join(:inner, [pbo, po], b in assoc(pbo, :block))
      |> select([pbo, po, b], b.number)
      |> update([pbo, po, b], set: [block_number: b.number])
      |> Repo.update_all([], timeout: @timeout)

    InternalTransaction.async_fetch(block_numbers)

    block_numbers
  end

  # =============================================================================
  # Metrics Helper Functions
  # =============================================================================

  defp record_batch_metrics(duration_seconds, count) do
    alias Indexer.Prometheus.Instrumenter

    if Code.ensure_loaded?(Instrumenter) do
      try do
        Instrumenter.fetcher_run_duration(:pending_block_operations_sanitizer, duration_seconds)

        if count > 0 do
          Instrumenter.fetcher_items_processed(:pending_block_operations_sanitizer, count)
        end
      rescue
        _ -> :ok
      end
    end
  end
end
