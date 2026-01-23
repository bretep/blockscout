import Config

config :ethereum_jsonrpc, EthereumJSONRPC.RequestCoordinator,
  rolling_window_opts: [
    window_count: 12,
    duration: :timer.minutes(1),
    table: EthereumJSONRPC.RequestCoordinator.TimeoutCounter
  ],
  max_jitter: :timer.seconds(2),
  # Global RPC request throttling - limits total requests to prevent node overload
  # 100 requests per 15 seconds = ~6.7 req/s sustained rate
  # Adjust based on your Erigon's capacity
  throttle_rate_limit: 100,
  throttle_rolling_window_opts: [
    window_count: 3,
    duration: :timer.seconds(15),
    table: EthereumJSONRPC.RequestCoordinator.ThrottleCounter
  ]

config :ethereum_jsonrpc, EthereumJSONRPC.Tracer,
  service: :ethereum_jsonrpc,
  adapter: SpandexDatadog.Adapter,
  trace_key: :blockscout

config :logger, :ethereum_jsonrpc,
  # keep synced with `config/config.exs`
  format: "$dateT$time $metadata[$level] $message\n",
  metadata:
    ~w(application fetcher request_id first_block_number last_block_number missing_block_range_count missing_block_count
       block_number step count error_count shrunk import_id transaction_id)a,
  metadata_filter: [application: :ethereum_jsonrpc]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
