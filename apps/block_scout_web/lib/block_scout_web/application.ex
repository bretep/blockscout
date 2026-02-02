defmodule BlockScoutWeb.Application do
  @moduledoc """
  Supervises `BlockScoutWeb.Endpoint` in order to serve Web UI.
  """

  use Application

  require Logger

  alias BlockScoutWeb.API.APILogger
  alias BlockScoutWeb.Counters.{BlocksIndexedCounter, InternalTransactionsIndexedCounter}
  alias BlockScoutWeb.Endpoint
  alias BlockScoutWeb.Prometheus
  alias BlockScoutWeb.{MainPageRealtimeEventHandler, RealtimeEventHandler}

  def start(_type, _args) do
    import Supervisor

    Prometheus.Instrumenter.setup()
    Prometheus.Exporter.setup()
    Prometheus.SSEInstrumenter.setup()
    Prometheus.ApiInstrumenter.setup()

    APILogger.message(
      "Current global API rate limit #{inspect(Application.get_env(:block_scout_web, :api_rate_limit)[:global_limit])} reqs/sec"
    )

    APILogger.message(
      "Current API rate limit by key #{inspect(Application.get_env(:block_scout_web, :api_rate_limit)[:limit_by_key])} reqs/sec"
    )

    APILogger.message(
      "Current API rate limit by IP #{inspect(Application.get_env(:block_scout_web, :api_rate_limit)[:limit_by_ip])} reqs/sec"
    )

    nats_url = Application.get_env(:block_scout_web, :nats_url)

    # Define workers and child supervisors to be supervised
    base_children = [
      pubsub_child_spec(),
      # Registry for SSE client subscriptions
      {Registry, keys: :duplicate, name: BlockScoutWeb.Nats.Registry},
      # SSE connection tracker - monitors handler processes for proper cleanup
      BlockScoutWeb.SSE.ConnectionTracker,
      child_spec(Endpoint, []),
      # Prometheus metrics on separate port (default 9568, configure with METRICS_PORT)
      Prometheus.MetricsEndpoint,
      {Absinthe.Subscription, Endpoint},
      {BlocksIndexedCounter, name: BlocksIndexedCounter},
      {InternalTransactionsIndexedCounter, name: InternalTransactionsIndexedCounter}
    ]

    # Add NATS subscriber OR legacy websocket handlers (not both)
    children = base_children ++ realtime_children(nats_url)

    opts = [strategy: :one_for_one, name: BlockScoutWeb.Supervisor, max_restarts: 1_000]
    Supervisor.start_link(children, opts)
  end

  defp pubsub_child_spec do
    # Always use default PG2 adapter for local Phoenix.PubSub
    # NATS is used separately for indexer->API server communication
    {Phoenix.PubSub, name: BlockScoutWeb.PubSub}
  end

  # Determine which realtime event handlers to start based on configuration:
  # - NATS + API-only: Use NATS subscriber (events come from NATS)
  # - NATS + Indexer-only: Nothing needed (events published to NATS for remote API servers)
  # - NATS + Both (single instance): Use local handlers (events already in Registry)
  # - No NATS: Use local handlers (events from Registry/postgres)
  defp realtime_children(nats_url) when is_binary(nats_url) do
    indexer_supervisor_config = Application.get_env(:indexer, Indexer.Supervisor, [])
    indexer_enabled = Keyword.get(indexer_supervisor_config, :enabled, false)
    webapp_disabled = Application.get_env(:block_scout_web, :disable_webapp, false)

    cond do
      !indexer_enabled ->
        # API-only server with NATS - subscribe to NATS for events from remote indexer
        Logger.info("[Application] API-only mode with NATS: Starting NATS subscriber")
        [{BlockScoutWeb.Nats.Subscriber, nats_url: nats_url}]

      webapp_disabled ->
        # Indexer-only server with NATS - no local handlers needed, events go to NATS
        Logger.info("[Application] Indexer-only mode with NATS: No local handlers needed")
        []

      true ->
        # Single instance (both indexer + API) with NATS
        # - Local handlers for websocket compatibility
        # - NATS subscriber for SSE (events round-trip through NATS)
        Logger.info("[Application] Single instance mode with NATS: Using local handlers + NATS subscriber for SSE")
        [
          {MainPageRealtimeEventHandler, name: MainPageRealtimeEventHandler},
          {RealtimeEventHandler, name: RealtimeEventHandler},
          {BlockScoutWeb.Nats.Subscriber, nats_url: nats_url}
        ]
    end
  end

  defp realtime_children(_no_nats) do
    # No NATS configured - use local handlers (events from Registry/postgres)
    Logger.info("[Application] No NATS: Using local handlers")
    [
      {MainPageRealtimeEventHandler, name: MainPageRealtimeEventHandler},
      {RealtimeEventHandler, name: RealtimeEventHandler}
    ]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    Endpoint.config_change(changed, removed)
    :ok
  end
end
