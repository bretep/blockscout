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

-- Kill slow COUNT/SUM queries after 5 minutes (prevents query pileup)
-- Added to cron: * * * * * /usr/local/bin/kill_slow_queries.sh
-- Script location: /usr/local/bin/kill_slow_queries.sh on database server (65.109.152.103)
-- Kills: SELECT count/sum on transactions, token_transfers, logs, internal_transactions
-- Preserves: CALL procedures, autovacuum, import queries
-- Log: /var/log/kill_slow_queries.log

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

-- =============================================================================
-- PER-ADDRESS COUNTERS TABLE
-- =============================================================================
--
-- Stores pre-computed transaction counts per address to avoid slow COUNT queries.
-- The slowest query pattern (125s avg, 89,653 minutes total) is:
--   SELECT count(t0."hash") FROM "transactions" WHERE to_address_hash = $1 OR from_address_hash = $1
--
-- This table stores those counts and updates them incrementally during indexing.

CREATE TABLE IF NOT EXISTS address_counters (
    address_hash bytea PRIMARY KEY,
    transactions_count bigint NOT NULL DEFAULT 0,
    token_transfers_count bigint NOT NULL DEFAULT 0,
    gas_used numeric(100,0) NOT NULL DEFAULT 0,
    last_block_number bigint NOT NULL DEFAULT 0,
    updated_at timestamp without time zone NOT NULL DEFAULT NOW()
);

-- Index for finding stale entries that need refresh
CREATE INDEX CONCURRENTLY IF NOT EXISTS address_counters_updated_at_idx
ON address_counters (updated_at);

-- Index for finding entries to update incrementally
CREATE INDEX CONCURRENTLY IF NOT EXISTS address_counters_last_block_number_idx
ON address_counters (last_block_number);

COMMENT ON TABLE address_counters IS 'Pre-computed per-address transaction/transfer counts to avoid slow COUNT queries';
COMMENT ON COLUMN address_counters.transactions_count IS 'Total transactions where address is from or to';
COMMENT ON COLUMN address_counters.token_transfers_count IS 'Total token transfers where address is from or to';
COMMENT ON COLUMN address_counters.gas_used IS 'Total gas used in transactions from this address';
COMMENT ON COLUMN address_counters.last_block_number IS 'Block number up to which counts are accurate (for incremental updates)';

-- =============================================================================
-- BACKFILL PROCEDURES FOR address_counters
-- =============================================================================
--
-- Uses PROCEDURE with COMMIT after each chunk to avoid long-running transactions.
-- This prevents blocking autovacuum and allows resuming if interrupted.
--
-- Phase 1: Transaction counts and gas_used (estimated: 4-8 hours for 2.3B txs)
-- Phase 2: Token transfer counts (estimated: 6-12 hours for 5.3B transfers)
--
-- Monitor progress:
--   SELECT COUNT(*) as addresses, MAX(last_block_number) as last_block FROM address_counters;
--   SELECT * FROM backfill_progress;

-- Progress tracking table
CREATE TABLE IF NOT EXISTS backfill_progress (
    phase TEXT PRIMARY KEY,
    current_block BIGINT NOT NULL DEFAULT 0,
    max_block BIGINT NOT NULL DEFAULT 0,
    rows_processed BIGINT NOT NULL DEFAULT 0,
    started_at TIMESTAMP,
    updated_at TIMESTAMP
);

-- -----------------------------------------------------------------------------
-- PHASE 1: Transaction counts and gas_used
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE backfill_address_counters_phase1(
    p_chunk_size INT DEFAULT 100000,
    p_start_block BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_block BIGINT;
    v_end_block BIGINT;
    v_max_block BIGINT;
    v_rows_affected BIGINT;
    v_total_rows BIGINT := 0;
    v_chunk_start TIMESTAMP;
BEGIN
    SELECT COALESCE(MAX(number), 0) INTO v_max_block FROM blocks WHERE consensus = true;

    -- Resume from checkpoint or start fresh
    IF p_start_block IS NOT NULL THEN
        v_start_block := p_start_block;
    ELSE
        SELECT COALESCE(current_block, 0) INTO v_start_block
        FROM backfill_progress WHERE phase = 'phase1';
        IF v_start_block IS NULL THEN
            v_start_block := 0;
        END IF;
    END IF;

    -- Initialize progress tracking
    INSERT INTO backfill_progress (phase, current_block, max_block, started_at, updated_at)
    VALUES ('phase1', v_start_block, v_max_block, NOW(), NOW())
    ON CONFLICT (phase) DO UPDATE SET
        max_block = v_max_block,
        updated_at = NOW();

    RAISE NOTICE 'Phase 1: Starting from block %, max block %', v_start_block, v_max_block;

    WHILE v_start_block <= v_max_block LOOP
        v_chunk_start := clock_timestamp();
        v_end_block := v_start_block + p_chunk_size - 1;

        -- Aggregate from/to addresses in this block range
        WITH tx_stats AS (
            SELECT
                address_hash,
                COUNT(*) as tx_count,
                SUM(gas) as gas_total
            FROM (
                SELECT from_address_hash as address_hash, gas_used as gas
                FROM transactions
                WHERE block_number >= v_start_block
                  AND block_number <= v_end_block
                  AND from_address_hash IS NOT NULL
                UNION ALL
                SELECT to_address_hash as address_hash, 0 as gas
                FROM transactions
                WHERE block_number >= v_start_block
                  AND block_number <= v_end_block
                  AND to_address_hash IS NOT NULL
            ) t
            GROUP BY address_hash
        )
        INSERT INTO address_counters (address_hash, transactions_count, gas_used, last_block_number, updated_at)
        SELECT address_hash, tx_count, gas_total, v_end_block, NOW()
        FROM tx_stats
        ON CONFLICT (address_hash) DO UPDATE SET
            transactions_count = address_counters.transactions_count + EXCLUDED.transactions_count,
            gas_used = address_counters.gas_used + EXCLUDED.gas_used,
            last_block_number = GREATEST(address_counters.last_block_number, EXCLUDED.last_block_number),
            updated_at = NOW();

        GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
        v_total_rows := v_total_rows + v_rows_affected;

        -- Update progress and COMMIT to release locks
        UPDATE backfill_progress
        SET current_block = v_end_block + 1,
            rows_processed = rows_processed + v_rows_affected,
            updated_at = NOW()
        WHERE phase = 'phase1';

        COMMIT;

        RAISE NOTICE 'Blocks %-% : % addresses (% ms)',
            v_start_block, v_end_block, v_rows_affected,
            EXTRACT(MILLISECONDS FROM clock_timestamp() - v_chunk_start)::INT;

        v_start_block := v_end_block + 1;

        -- Brief pause to reduce I/O pressure
        PERFORM pg_sleep(0.05);
    END LOOP;

    RAISE NOTICE 'Phase 1 complete. Total rows processed: %', v_total_rows;
END $$;

-- -----------------------------------------------------------------------------
-- PHASE 2: Token transfer counts
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE backfill_address_counters_phase2(
    p_chunk_size INT DEFAULT 100000,
    p_start_block BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_block BIGINT;
    v_end_block BIGINT;
    v_max_block BIGINT;
    v_rows_affected BIGINT;
    v_total_rows BIGINT := 0;
    v_chunk_start TIMESTAMP;
BEGIN
    SELECT COALESCE(MAX(number), 0) INTO v_max_block FROM blocks WHERE consensus = true;

    IF p_start_block IS NOT NULL THEN
        v_start_block := p_start_block;
    ELSE
        SELECT COALESCE(current_block, 0) INTO v_start_block
        FROM backfill_progress WHERE phase = 'phase2';
        IF v_start_block IS NULL THEN
            v_start_block := 0;
        END IF;
    END IF;

    INSERT INTO backfill_progress (phase, current_block, max_block, started_at, updated_at)
    VALUES ('phase2', v_start_block, v_max_block, NOW(), NOW())
    ON CONFLICT (phase) DO UPDATE SET
        max_block = v_max_block,
        updated_at = NOW();

    RAISE NOTICE 'Phase 2: Starting from block %, max block %', v_start_block, v_max_block;

    WHILE v_start_block <= v_max_block LOOP
        v_chunk_start := clock_timestamp();
        v_end_block := v_start_block + p_chunk_size - 1;

        WITH tt_stats AS (
            SELECT
                address_hash,
                COUNT(*) as tt_count
            FROM (
                SELECT from_address_hash as address_hash
                FROM token_transfers
                WHERE block_number >= v_start_block
                  AND block_number <= v_end_block
                  AND from_address_hash IS NOT NULL
                UNION ALL
                SELECT to_address_hash as address_hash
                FROM token_transfers
                WHERE block_number >= v_start_block
                  AND block_number <= v_end_block
                  AND to_address_hash IS NOT NULL
            ) t
            GROUP BY address_hash
        )
        INSERT INTO address_counters (address_hash, token_transfers_count, last_block_number, updated_at)
        SELECT address_hash, tt_count, v_end_block, NOW()
        FROM tt_stats
        ON CONFLICT (address_hash) DO UPDATE SET
            token_transfers_count = address_counters.token_transfers_count + EXCLUDED.token_transfers_count,
            last_block_number = GREATEST(address_counters.last_block_number, EXCLUDED.last_block_number),
            updated_at = NOW();

        GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
        v_total_rows := v_total_rows + v_rows_affected;

        UPDATE backfill_progress
        SET current_block = v_end_block + 1,
            rows_processed = rows_processed + v_rows_affected,
            updated_at = NOW()
        WHERE phase = 'phase2';

        COMMIT;

        RAISE NOTICE 'Blocks %-% : % addresses (% ms)',
            v_start_block, v_end_block, v_rows_affected,
            EXTRACT(MILLISECONDS FROM clock_timestamp() - v_chunk_start)::INT;

        v_start_block := v_end_block + 1;
        PERFORM pg_sleep(0.05);
    END LOOP;

    RAISE NOTICE 'Phase 2 complete. Total rows processed: %', v_total_rows;
END $$;

-- =============================================================================
-- PARALLEL BACKFILL WITH STAGING TABLES
-- =============================================================================
--
-- The single-threaded procedures above are replaced with parallel-safe versions
-- that use staging tables to avoid deadlocks when multiple workers update the
-- same addresses.
--
-- Pattern:
-- 1. Each worker writes to staging table with worker_id in primary key
-- 2. Workers can't deadlock because they only touch their own rows
-- 3. After all workers complete, merge staging data into address_counters
--
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PHASE 1 STAGING (Transactions) - Already created and running
-- -----------------------------------------------------------------------------

-- Staging table for parallel transaction backfill
CREATE TABLE IF NOT EXISTS address_counters_staging (
    worker_id TEXT NOT NULL,
    address_hash bytea NOT NULL,
    transactions_count bigint NOT NULL DEFAULT 0,
    gas_used numeric(100,0) NOT NULL DEFAULT 0,
    block_start bigint NOT NULL,
    block_end bigint NOT NULL,
    PRIMARY KEY (worker_id, address_hash)
);

-- Progress tracking per worker
CREATE TABLE IF NOT EXISTS backfill_worker_progress (
    worker_id TEXT PRIMARY KEY,
    start_block BIGINT NOT NULL,
    current_block BIGINT NOT NULL,
    end_block BIGINT NOT NULL,
    rows_processed BIGINT DEFAULT 0,
    started_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Phase 1 parallel procedure (transactions + gas)
CREATE OR REPLACE PROCEDURE backfill_address_counters_staging(
    p_start_block BIGINT,
    p_end_block BIGINT,
    p_chunk_size INT DEFAULT 100,
    p_worker_id TEXT DEFAULT 'W1'
)
LANGUAGE plpgsql
AS $proc$
DECLARE
    v_current_block BIGINT;
    v_chunk_end BIGINT;
    v_rows_affected BIGINT;
    v_total_rows BIGINT := 0;
    v_chunk_start TIMESTAMP;
    v_pct NUMERIC;
BEGIN
    -- Check for existing progress to resume
    SELECT current_block INTO v_current_block
    FROM backfill_worker_progress
    WHERE worker_id = p_worker_id;

    IF v_current_block IS NULL THEN
        v_current_block := p_start_block;
        INSERT INTO backfill_worker_progress (worker_id, start_block, current_block, end_block)
        VALUES (p_worker_id, p_start_block, p_start_block, p_end_block);
    ELSE
        RAISE NOTICE '[%] Resuming from block %', p_worker_id, v_current_block;
    END IF;

    WHILE v_current_block < p_end_block LOOP
        v_chunk_start := clock_timestamp();
        v_chunk_end := LEAST(v_current_block + p_chunk_size - 1, p_end_block - 1);

        -- Aggregate transactions in this chunk
        WITH tx_stats AS (
            SELECT address_hash, COUNT(*) as tx_count, SUM(gas) as gas_total
            FROM (
                SELECT from_address_hash as address_hash, gas_used as gas
                FROM transactions
                WHERE block_number >= v_current_block AND block_number <= v_chunk_end
                  AND from_address_hash IS NOT NULL
                UNION ALL
                SELECT to_address_hash as address_hash, 0 as gas
                FROM transactions
                WHERE block_number >= v_current_block AND block_number <= v_chunk_end
                  AND to_address_hash IS NOT NULL
            ) t
            GROUP BY address_hash
        )
        INSERT INTO address_counters_staging (worker_id, address_hash, transactions_count, gas_used, block_start, block_end)
        SELECT p_worker_id, address_hash, tx_count, gas_total, p_start_block, p_end_block
        FROM tx_stats
        ON CONFLICT (worker_id, address_hash) DO UPDATE SET
            transactions_count = address_counters_staging.transactions_count + EXCLUDED.transactions_count,
            gas_used = address_counters_staging.gas_used + EXCLUDED.gas_used;

        GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
        v_total_rows := v_total_rows + v_rows_affected;
        v_current_block := v_chunk_end + 1;

        -- Update progress
        UPDATE backfill_worker_progress
        SET current_block = v_current_block, rows_processed = rows_processed + v_rows_affected, updated_at = NOW()
        WHERE worker_id = p_worker_id;

        COMMIT;

        -- Progress notification every 10k blocks
        IF v_current_block % 10000 < p_chunk_size THEN
            v_pct := 100.0 * (v_current_block - p_start_block) / NULLIF(p_end_block - p_start_block, 0);
            RAISE NOTICE '[%] Block % (%.1f%%) : % addr (% ms)',
                p_worker_id, v_current_block, v_pct, v_rows_affected,
                EXTRACT(MILLISECONDS FROM clock_timestamp() - v_chunk_start)::INT;
        END IF;

        PERFORM pg_sleep(0.01);
    END LOOP;

    RAISE NOTICE '[%] Complete. Total addresses processed: %', p_worker_id, v_total_rows;
END $proc$;

-- Merge Phase 1 staging into address_counters
CREATE OR REPLACE PROCEDURE merge_phase1_staging()
LANGUAGE plpgsql
AS $proc$
DECLARE
    v_rows_affected BIGINT;
BEGIN
    RAISE NOTICE 'Merging Phase 1 staging data into address_counters...';

    -- Aggregate all workers and merge
    WITH aggregated AS (
        SELECT
            address_hash,
            SUM(transactions_count) as total_tx,
            SUM(gas_used) as total_gas,
            MAX(block_end) as max_block
        FROM address_counters_staging
        GROUP BY address_hash
    )
    INSERT INTO address_counters (address_hash, transactions_count, gas_used, last_block_number, updated_at)
    SELECT address_hash, total_tx, total_gas, max_block, NOW()
    FROM aggregated
    ON CONFLICT (address_hash) DO UPDATE SET
        transactions_count = EXCLUDED.transactions_count,
        gas_used = EXCLUDED.gas_used,
        last_block_number = GREATEST(address_counters.last_block_number, EXCLUDED.last_block_number),
        updated_at = NOW();

    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
    RAISE NOTICE 'Phase 1 merge complete. % addresses updated.', v_rows_affected;
END $proc$;

-- -----------------------------------------------------------------------------
-- PHASE 2 STAGING (Token Transfers)
-- -----------------------------------------------------------------------------

-- Staging table for parallel token transfer backfill
CREATE TABLE IF NOT EXISTS address_counters_tt_staging (
    worker_id TEXT NOT NULL,
    address_hash bytea NOT NULL,
    token_transfers_count bigint NOT NULL DEFAULT 0,
    block_start bigint NOT NULL,
    block_end bigint NOT NULL,
    PRIMARY KEY (worker_id, address_hash)
);

-- Progress tracking for Phase 2 workers
CREATE TABLE IF NOT EXISTS backfill_tt_worker_progress (
    worker_id TEXT PRIMARY KEY,
    start_block BIGINT NOT NULL,
    current_block BIGINT NOT NULL,
    end_block BIGINT NOT NULL,
    rows_processed BIGINT DEFAULT 0,
    started_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Phase 2 parallel procedure (token transfers)
CREATE OR REPLACE PROCEDURE backfill_address_counters_tt_staging(
    p_start_block BIGINT,
    p_end_block BIGINT,
    p_chunk_size INT DEFAULT 100,
    p_worker_id TEXT DEFAULT 'T1'
)
LANGUAGE plpgsql
AS $proc$
DECLARE
    v_current_block BIGINT;
    v_chunk_end BIGINT;
    v_rows_affected BIGINT;
    v_total_rows BIGINT := 0;
    v_chunk_start TIMESTAMP;
    v_pct NUMERIC;
BEGIN
    -- Check for existing progress to resume
    SELECT current_block INTO v_current_block
    FROM backfill_tt_worker_progress
    WHERE worker_id = p_worker_id;

    IF v_current_block IS NULL THEN
        v_current_block := p_start_block;
        INSERT INTO backfill_tt_worker_progress (worker_id, start_block, current_block, end_block)
        VALUES (p_worker_id, p_start_block, p_start_block, p_end_block);
    ELSE
        RAISE NOTICE '[%] Resuming from block %', p_worker_id, v_current_block;
    END IF;

    WHILE v_current_block < p_end_block LOOP
        v_chunk_start := clock_timestamp();
        v_chunk_end := LEAST(v_current_block + p_chunk_size - 1, p_end_block - 1);

        -- Aggregate token transfers in this chunk
        WITH tt_stats AS (
            SELECT address_hash, COUNT(*) as tt_count
            FROM (
                SELECT from_address_hash as address_hash
                FROM token_transfers
                WHERE block_number >= v_current_block AND block_number <= v_chunk_end
                  AND from_address_hash IS NOT NULL
                UNION ALL
                SELECT to_address_hash as address_hash
                FROM token_transfers
                WHERE block_number >= v_current_block AND block_number <= v_chunk_end
                  AND to_address_hash IS NOT NULL
            ) t
            GROUP BY address_hash
        )
        INSERT INTO address_counters_tt_staging (worker_id, address_hash, token_transfers_count, block_start, block_end)
        SELECT p_worker_id, address_hash, tt_count, p_start_block, p_end_block
        FROM tt_stats
        ON CONFLICT (worker_id, address_hash) DO UPDATE SET
            token_transfers_count = address_counters_tt_staging.token_transfers_count + EXCLUDED.token_transfers_count;

        GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
        v_total_rows := v_total_rows + v_rows_affected;
        v_current_block := v_chunk_end + 1;

        -- Update progress
        UPDATE backfill_tt_worker_progress
        SET current_block = v_current_block, rows_processed = rows_processed + v_rows_affected, updated_at = NOW()
        WHERE worker_id = p_worker_id;

        COMMIT;

        -- Progress notification every 10k blocks
        IF v_current_block % 10000 < p_chunk_size THEN
            v_pct := 100.0 * (v_current_block - p_start_block) / NULLIF(p_end_block - p_start_block, 0);
            RAISE NOTICE '[%] Block % (%.1f%%) : % addr (% ms)',
                p_worker_id, v_current_block, v_pct, v_rows_affected,
                EXTRACT(MILLISECONDS FROM clock_timestamp() - v_chunk_start)::INT;
        END IF;

        PERFORM pg_sleep(0.01);
    END LOOP;

    RAISE NOTICE '[%] Complete. Total addresses processed: %', p_worker_id, v_total_rows;
END $proc$;

-- Merge Phase 2 staging into address_counters
CREATE OR REPLACE PROCEDURE merge_phase2_staging()
LANGUAGE plpgsql
AS $proc$
DECLARE
    v_rows_affected BIGINT;
BEGIN
    RAISE NOTICE 'Merging Phase 2 staging data into address_counters...';

    -- Aggregate all workers and merge
    WITH aggregated AS (
        SELECT
            address_hash,
            SUM(token_transfers_count) as total_tt,
            MAX(block_end) as max_block
        FROM address_counters_tt_staging
        GROUP BY address_hash
    )
    INSERT INTO address_counters (address_hash, token_transfers_count, last_block_number, updated_at)
    SELECT address_hash, total_tt, max_block, NOW()
    FROM aggregated
    ON CONFLICT (address_hash) DO UPDATE SET
        token_transfers_count = EXCLUDED.token_transfers_count,
        last_block_number = GREATEST(address_counters.last_block_number, EXCLUDED.last_block_number),
        updated_at = NOW();

    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
    RAISE NOTICE 'Phase 2 merge complete. % addresses updated.', v_rows_affected;
END $proc$;

-- -----------------------------------------------------------------------------
-- USAGE (Parallel Backfill)
-- -----------------------------------------------------------------------------
--
-- PHASE 1 (Transactions):
-- 1. Calculate block ranges for N workers (e.g., 3 workers for 25.5M blocks = 8.5M each)
-- 2. Run in separate tmux windows:
--      SET statement_timeout = 0; CALL backfill_address_counters_staging(0, 8520000, 100, 'W1');
--      SET statement_timeout = 0; CALL backfill_address_counters_staging(8520000, 17040000, 100, 'W2');
--      SET statement_timeout = 0; CALL backfill_address_counters_staging(17040000, 25560000, 100, 'W3');
-- 3. Monitor: SELECT * FROM backfill_worker_progress ORDER BY worker_id;
-- 4. When all complete: CALL merge_phase1_staging();
-- 5. Cleanup: TRUNCATE address_counters_staging; DELETE FROM backfill_worker_progress;
--
-- PHASE 2 (Token Transfers):
-- 1. Same pattern with backfill_address_counters_tt_staging procedure
-- 2. Use T1, T2, T3 worker IDs to distinguish from Phase 1
-- 3. Monitor: SELECT * FROM backfill_tt_worker_progress ORDER BY worker_id;
-- 4. When all complete: CALL merge_phase2_staging();
-- 5. Cleanup: TRUNCATE address_counters_tt_staging; DELETE FROM backfill_tt_worker_progress;
--
-- To reset and start over:
--   TRUNCATE address_counters_staging, address_counters_tt_staging, address_counters;
--   DELETE FROM backfill_worker_progress;
--   DELETE FROM backfill_tt_worker_progress;
