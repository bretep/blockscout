defmodule Explorer.Chain.Cache.ContractsCounter do
  @moduledoc """
  Caches the number of contracts.

  It loads the count asynchronously and in a time interval of 30 minutes.
  """

  use GenServer

  alias Explorer.Chain

  @counter_type "contracts_counter"

  # It is undesirable to automatically start the consolidation in all environments.
  # Consider the test environment: if the consolidation initiates but does not
  # finish before a test ends, that test will fail. This way, hundreds of
  # tests were failing before disabling the consolidation and the scheduler in
  # the test env.
  config = Application.compile_env(:explorer, Explorer.Chain.Cache.ContractsCounter)
  @enable_consolidation Keyword.get(config, :enable_consolidation)

  @update_interval_in_milliseconds Keyword.get(config, :update_interval_in_milliseconds)

  @doc """
  Starts a process to periodically update the counter of all the contracts.
  """
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    {:ok, %{consolidate?: enable_consolidation?()}, {:continue, :ok}}
  end

  defp schedule_next_consolidation do
    Process.send_after(self(), :consolidate, @update_interval_in_milliseconds)
  end

  @impl true
  def handle_continue(:ok, %{consolidate?: true} = state) do
    consolidate()
    schedule_next_consolidation()

    {:noreply, state}
  end

  @impl true
  def handle_continue(:ok, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:consolidate, state) do
    start_time = System.monotonic_time(:microsecond)

    consolidate()

    duration = (System.monotonic_time(:microsecond) - start_time) / 1_000_000
    record_consolidation_metrics(duration)

    schedule_next_consolidation()

    {:noreply, state}
  end

  @doc """
  Fetches the value for a `#{@counter_type}` counter type from the `last_fetched_counters` table.
  """
  def fetch(options) do
    Chain.get_last_fetched_counter(@counter_type, options)
  end

  @doc """
  Consolidates the info by populating the `last_fetched_counters` table with the current database information.
  Only updates if the new count is >= current count to prevent counts going backwards.
  """
  def consolidate do
    new_counter = Chain.count_contracts()
    current_counter = fetch([]) || 0

    # Only update if new value is >= current to prevent counts going backwards
    if new_counter >= current_counter do
      params = %{
        counter_type: @counter_type,
        value: new_counter
      }

      Chain.upsert_last_fetched_counter(params)
    end
  end

  @doc """
  Returns a boolean that indicates whether consolidation is enabled

  In order to choose whether or not to enable the scheduler and the initial
  consolidation, change the following Explorer config:

  `config :explorer, Explorer.Chain.Cache.ContractsCounter, enable_consolidation: true`

  to:

  `config :explorer, Explorer.Chain.Cache.ContractsCounter, enable_consolidation: false`
  """
  def enable_consolidation?, do: @enable_consolidation

  # =============================================================================
  # Metrics Helper Functions
  # =============================================================================

  defp record_consolidation_metrics(duration_seconds) do
    alias Explorer.Prometheus.Instrumenter

    if Code.ensure_loaded?(Instrumenter) do
      try do
        Instrumenter.cache_consolidation(:contracts_counter, :periodic, duration_seconds)
      rescue
        _ -> :ok
      end
    end
  end
end
