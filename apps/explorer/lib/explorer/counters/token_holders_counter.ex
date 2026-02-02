defmodule Explorer.Counters.TokenHoldersCounter do
  @moduledoc """
  Caches Token holders counter.
  """
  use GenServer

  alias Explorer.Chain
  alias Explorer.Counters.Helper
  alias Explorer.Prometheus.Instrumenter

  @cache_name :token_holders_counter
  @last_update_key "last_update"

  config = Application.compile_env(:explorer, Explorer.Counters.TokenHoldersCounter)
  @enable_consolidation Keyword.get(config, :enable_consolidation)

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    create_cache_table()

    {:ok, %{consolidate?: enable_consolidation?()}, {:continue, :ok}}
  end

  @impl true
  def handle_continue(:ok, %{consolidate?: true} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_continue(:ok, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:consolidate, state) do
    {:noreply, state}
  end

  def fetch(address_hash) do
    cache_miss = cache_expired?(address_hash)

    if cache_miss do
      update_cache(address_hash)
      record_cache_metric(:miss)
    else
      record_cache_metric(:hit)
    end

    address_hash_string = to_string(address_hash)
    fetch_from_cache("hash_#{address_hash_string}")
  end

  def cache_name, do: @cache_name

  defp cache_expired?(address_hash) do
    cache_period = Application.get_env(:explorer, __MODULE__)[:cache_period]
    address_hash_string = to_string(address_hash)
    updated_at = fetch_from_cache("hash_#{address_hash_string}_#{@last_update_key}")

    cond do
      is_nil(updated_at) -> true
      Helper.current_time() - updated_at > cache_period -> true
      true -> false
    end
  end

  defp update_cache(address_hash) do
    address_hash_string = to_string(address_hash)
    put_into_cache("hash_#{address_hash_string}_#{@last_update_key}", Helper.current_time())

    start_time = System.monotonic_time(:microsecond)
    new_data = Chain.count_token_holders_from_token_hash(address_hash)
    duration = (System.monotonic_time(:microsecond) - start_time) / 1_000_000
    record_query_metric(duration)

    put_into_cache("hash_#{address_hash_string}", new_data)
  end

  defp fetch_from_cache(key) do
    Helper.fetch_from_cache(key, @cache_name)
  end

  defp put_into_cache(key, value) do
    :ets.insert(@cache_name, {key, value})
  end

  defp create_cache_table do
    Helper.create_cache_table(@cache_name)
  end

  defp enable_consolidation?, do: @enable_consolidation

  # Record cache hit/miss metrics
  defp record_cache_metric(result) do
    if Code.ensure_loaded?(Instrumenter) do
      try do
        Instrumenter.token_holders_cache(result)
      rescue
        _ -> :ok
      end
    end
  end

  # Record query duration metrics
  defp record_query_metric(duration_seconds) do
    if Code.ensure_loaded?(Instrumenter) do
      try do
        Instrumenter.token_query(:holders_count, duration_seconds)
      rescue
        _ -> :ok
      end
    end
  end
end
