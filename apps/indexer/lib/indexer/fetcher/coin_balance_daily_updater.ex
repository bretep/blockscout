defmodule Indexer.Fetcher.CoinBalanceDailyUpdater do
  @moduledoc """
  Accumulates and periodically updates daily coin balances
  """

  use GenServer

  alias Explorer.Chain
  alias Explorer.Counters.AverageBlockTime
  alias Timex.Duration

  @default_update_interval :timer.seconds(10)

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(_) do
    schedule_next_update()

    {:ok, %{}}
  end

  def add_daily_balances_params(daily_balances_params) do
    GenServer.cast(__MODULE__, {:add_daily_balances_params, daily_balances_params})
  end

  @impl true
  def handle_cast({:add_daily_balances_params, daily_balances_params}, state) do
    {:noreply, Enum.reduce(daily_balances_params, state, &put_new_param/2)}
  end

  defp put_new_param(%{day: day, address_hash: address_hash, value: value} = param, acc) do
    Map.update(acc, {address_hash, day}, param, fn %{value: old_value} = old_param ->
      if is_nil(old_value) or value > old_value, do: param, else: old_param
    end)
  end

  @impl true
  def handle_info(:update, state) when state == %{} do
    schedule_next_update()

    {:noreply, %{}}
  end

  def handle_info(:update, state) do
    start_time = System.monotonic_time(:microsecond)
    count = map_size(state)

    result = Chain.import(%{address_coin_balances_daily: %{params: Map.values(state)}})

    duration = (System.monotonic_time(:microsecond) - start_time) / 1_000_000
    record_update_metrics(duration, count, result)

    schedule_next_update()

    {:noreply, %{}}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  defp schedule_next_update do
    update_interval =
      case AverageBlockTime.average_block_time() do
        {:error, :disabled} -> @default_update_interval
        block_time -> round(Duration.to_milliseconds(block_time))
      end

    Process.send_after(self(), :update, update_interval)
  end

  # =============================================================================
  # Metrics Helper Functions
  # =============================================================================

  defp record_update_metrics(duration_seconds, count, result) do
    alias Indexer.Prometheus.Instrumenter

    if Code.ensure_loaded?(Instrumenter) do
      try do
        Instrumenter.fetcher_run_duration(:coin_balance_daily, duration_seconds)

        case result do
          {:ok, _} ->
            Instrumenter.fetcher_items_processed(:coin_balance_daily, count)

          {:error, _} ->
            Instrumenter.fetcher_error(:coin_balance_daily, :import_error)

          _ ->
            :ok
        end
      rescue
        _ -> :ok
      end
    end
  end
end
