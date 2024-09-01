import Config

# Configures the database
config :explorer, Explorer.Repo,
  prepare: :unnamed,
  timeout: :timer.seconds(300),
  queue_target: 5000,
  queue_interval: 10000,
  migration_lock: nil

# Configures API the database
config :explorer, Explorer.Repo.Replica1,
  prepare: :unnamed,
  queue_target: 5000,
  queue_interval: 10000,
  timeout: :timer.seconds(300)

# Configures Account database
config :explorer, Explorer.Repo.Account,
  prepare: :unnamed,
  timeout: :timer.seconds(300)

config :explorer, Explorer.Repo.PolygonEdge,
  prepare: :unnamed,
  timeout: :timer.seconds(300)

config :explorer, Explorer.Repo.PolygonZkevm,
  prepare: :unnamed,
  timeout: :timer.seconds(300)

config :explorer, Explorer.Repo.RSK,
  prepare: :unnamed,
  timeout: :timer.seconds(300)

config :explorer, Explorer.Repo.Suave,
  prepare: :unnamed,
  timeout: :timer.seconds(300)

config :explorer, Explorer.Tracer, env: "production", disabled?: true

config :logger, :explorer,
  level: :info,
  path: Path.absname("logs/prod/explorer.log"),
  rotate: %{max_bytes: 52_428_800, keep: 19}

config :logger, :reading_token_functions,
  level: :debug,
  path: Path.absname("logs/prod/explorer/tokens/reading_functions.log"),
  metadata_filter: [fetcher: :token_functions],
  rotate: %{max_bytes: 52_428_800, keep: 19}

config :logger, :token_instances,
  level: :debug,
  path: Path.absname("logs/prod/explorer/tokens/token_instances.log"),
  metadata_filter: [fetcher: :token_instances],
  rotate: %{max_bytes: 52_428_800, keep: 19}
