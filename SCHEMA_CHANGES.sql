-- Schema changes applied to production database (65.109.152.103)
-- These should be added to migrations or re-run on other databases
-- Date: 2026-01-16

-- =============================================================================
-- INDEXES
-- =============================================================================

-- Partial index for fast contract address lookups
-- Speeds up: SELECT count(*) FROM addresses WHERE contract_code IS NOT NULL
-- From ~28 minutes to <1 second
CREATE INDEX CONCURRENTLY IF NOT EXISTS addresses_contract_code_partial_idx
ON addresses (hash) WHERE contract_code IS NOT NULL;

-- =============================================================================
-- GLOBAL AUTOVACUUM SETTINGS (via ALTER SYSTEM)
-- =============================================================================

-- Throttle autovacuum to reduce I/O contention with user queries
-- Default was 0 (no throttling), which caused ~200 queries waiting on I/O
ALTER SYSTEM SET autovacuum_vacuum_cost_delay = 5;  -- 5ms pause per cost_limit
SELECT pg_reload_conf();

-- =============================================================================
-- PER-TABLE AUTOVACUUM SETTINGS
-- =============================================================================

-- Aggressive autovacuum for largest/most active tables
ALTER TABLE internal_transactions SET (
    autovacuum_vacuum_scale_factor = 0.001,
    autovacuum_vacuum_threshold = 10000,
    autovacuum_analyze_scale_factor = 0.0005
);

ALTER TABLE logs SET (
    autovacuum_vacuum_scale_factor = 0.001,
    autovacuum_vacuum_threshold = 10000,
    autovacuum_analyze_scale_factor = 0.0005
);

ALTER TABLE token_transfers SET (
    autovacuum_vacuum_scale_factor = 0.001,
    autovacuum_vacuum_threshold = 10000,
    autovacuum_analyze_scale_factor = 0.0005
);

ALTER TABLE transactions SET (
    autovacuum_vacuum_scale_factor = 0.001,
    autovacuum_vacuum_threshold = 10000,
    autovacuum_analyze_scale_factor = 0.0005
);

ALTER TABLE address_token_balances SET (
    autovacuum_vacuum_scale_factor = 0.001,
    autovacuum_vacuum_threshold = 10000,
    autovacuum_analyze_scale_factor = 0.0005
);

ALTER TABLE address_coin_balances SET (
    autovacuum_vacuum_scale_factor = 0.001,
    autovacuum_vacuum_threshold = 10000,
    autovacuum_analyze_scale_factor = 0.0005
);

ALTER TABLE addresses SET (
    autovacuum_vacuum_scale_factor = 0.005,
    autovacuum_vacuum_threshold = 5000,
    autovacuum_analyze_scale_factor = 0.0025
);

ALTER TABLE token_instances SET (
    autovacuum_vacuum_scale_factor = 0.005,
    autovacuum_vacuum_threshold = 5000,
    autovacuum_analyze_scale_factor = 0.0025
);

ALTER TABLE blocks SET (
    autovacuum_vacuum_scale_factor = 0.01,
    autovacuum_vacuum_threshold = 1000,
    autovacuum_analyze_scale_factor = 0.005
);

ALTER TABLE address_current_token_balances SET (
    autovacuum_vacuum_scale_factor = 0.005,
    autovacuum_vacuum_threshold = 5000,
    autovacuum_analyze_scale_factor = 0.0025
);

ALTER TABLE address_coin_balances_daily SET (
    autovacuum_vacuum_scale_factor = 0.01,
    autovacuum_vacuum_threshold = 1000,
    autovacuum_analyze_scale_factor = 0.005
);

-- =============================================================================
-- MAINTENANCE TASKS (run periodically, not migrations)
-- =============================================================================

-- Truncate event_notifications daily (not needed, uses NOTIFY)
-- Added to cron: 0 4 * * * docker exec pulse-postgres-1 psql -U blockscout -d blockscout -c "TRUNCATE public.event_notifications;"

-- =============================================================================
-- ELIXIR CODE CHANGES (for counter performance)
-- =============================================================================
--
-- The following slow count queries were optimized to use pg_class.reltuples
-- estimates instead of full table scans:
--
-- 1. count_contracts() in apps/explorer/lib/explorer/chain.ex
--    - Changed to use addresses_contract_code_partial_idx reltuples
--    - From ~28 minutes to instant
--
-- 2. count_addresses() in apps/explorer/lib/explorer/chain/address/counters.ex
--    - Changed to use pg_class.reltuples for addresses table
--    - From ~5 minutes to instant
--
-- 3. count_addresses_with_balance() in apps/explorer/lib/explorer/chain/address/counters.ex
--    - Changed to use addresses_fetched_coin_balance_hash_index reltuples
--    - From ~6 minutes to instant
--
-- The estimates are updated automatically by PostgreSQL's ANALYZE which runs
-- during autovacuum. For the partial indexes, the estimates are very accurate
-- since they directly represent the filtered row counts.
--
-- IMPORTANT: The partial index addresses_contract_code_partial_idx MUST exist
-- for the contract count optimization to work. If migrating to a new database,
-- create this index first before deploying the code changes.
--
-- 4. Transaction count cache in apps/explorer/lib/explorer/chain/cache/transaction.ex
--    - Changed handle_fallback to use Helper.estimated_count_from("transactions")
--    - From 30+ minutes full table scan to instant pg_class.reltuples
--
-- 5. Gas usage sum in apps/explorer/lib/explorer/chain/cache/gas_usage.ex
--    - Disabled - SUM on 2.3B rows cannot be optimized with pg_class
--    - Returns 0 (display stat only)
--
-- 6. Total supply in apps/explorer/lib/explorer/etherscan.ex
--    - Disabled fetch_sum_coin_total_supply() and fetch_sum_coin_total_supply_minus_burnt()
--    - SUM on 414M addresses table takes 15+ minutes
--    - Returns 0 (API should use pre-computed value)
--
-- 7. New contracts count in apps/explorer/lib/explorer/chain.ex
--    - Disabled count_new_contracts()
--    - Scanned 2.3B transactions for 24h window
--    - Would need index on created_contract_code_indexed_at to be fast
--    - Returns 0 for now
--
-- =============================================================================
-- INCREMENTAL COUNTERS (for accurate counts without full table scans)
-- =============================================================================
--
-- For counters that need accurate values (not just estimates), we use an
-- incremental approach that stores a checkpoint (block_number) and only
-- counts/sums new data since the last checkpoint.
--
-- 8. TransactionsCounter in apps/explorer/lib/explorer/chain/cache/transactions_counter.ex
--    - Subscribes to :blocks events for real-time updates
--    - Stores count + checkpoint block_number in last_fetched_counters table
--    - On first run: does full accurate count (may take 30+ min, but only once)
--    - On each new block: counts only transactions WHERE block_number > checkpoint (milliseconds)
--    - Adds incremental count to stored total
--    - Updates checkpoint to current max(block_number)
--    - Only runs on indexer (DISABLE_INDEXER=false), API servers just read
--
-- 9. GasUsageCounter in apps/explorer/lib/explorer/chain/cache/gas_usage_counter.ex
--    - Same pattern as TransactionsCounter but for SUM(gas_used)
--    - On first run: does full accurate sum (may take 30+ min, but only once)
--    - On each new block: sums only gas_used WHERE block_number > checkpoint (milliseconds)
--    - Only runs on indexer (DISABLE_INDEXER=false), API servers just read
--
-- The counters use last_fetched_counters table with entries like:
--   transactions_counter = 2378818093
--   transactions_counter_checkpoint = 21000000
--   gas_usage_counter = 123456789012345
--   gas_usage_counter_checkpoint = 21000000
