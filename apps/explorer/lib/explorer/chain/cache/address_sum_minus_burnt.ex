defmodule Explorer.Chain.Cache.AddressSumMinusBurnt do
  @moduledoc """
  Cache for address sum minus burnt number.
  """

  require Logger

  use Explorer.Chain.MapCache,
    name: :address_sum_minus_burnt,
    key: :sum_minus_burnt,
    key: :async_task,
    ttl_check_interval: Application.get_env(:explorer, __MODULE__)[:ttl_check_interval],
    global_ttl: Application.get_env(:explorer, __MODULE__)[:global_ttl],
    callback: &async_task_on_deletion(&1)

  alias Explorer.{Chain, Etherscan}

  defp handle_fallback(:sum_minus_burnt) do
    # This will get the task PID if one exists and launch a new task if not
    # See next `handle_fallback` definition
    get_async_task()

    {:return, Decimal.new(0)}
  end

  defp handle_fallback(:async_task) do
    # If this gets called it means an async task was requested, but none exists
    # so a new one needs to be launched
    {:ok, task} =
      Task.start(fn ->
        try do
          start_time = System.monotonic_time(:microsecond)
          result = Etherscan.fetch_sum_coin_total_supply_minus_burnt()
          duration = (System.monotonic_time(:microsecond) - start_time) / 1_000_000
          record_query_metrics(duration)

          params = %{
            counter_type: "sum_coin_total_supply_minus_burnt",
            value: result
          }

          Chain.upsert_last_fetched_counter(params)

          set_sum_minus_burnt(result)
        rescue
          e ->
            Logger.debug([
              "Couldn't update address sum: ",
              Exception.format(:error, e, __STACKTRACE__)
            ])
        end

        set_async_task(nil)
      end)

    {:update, task}
  end

  # By setting this as a `callback` an async task will be started each time the
  # `sum_minus_burnt` expires (unless there is one already running)
  defp async_task_on_deletion({:delete, _, :sum_minus_burnt}), do: get_async_task()

  defp async_task_on_deletion(_data), do: nil

  # =============================================================================
  # Metrics Helper Functions
  # =============================================================================

  defp record_query_metrics(duration_seconds) do
    alias Explorer.Prometheus.Instrumenter

    if Code.ensure_loaded?(Instrumenter) do
      try do
        Instrumenter.cache_consolidation(:address_sum_minus_burnt, :on_demand, duration_seconds)
      rescue
        _ -> :ok
      end
    end
  end
end
