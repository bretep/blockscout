defmodule Explorer.Chain.Cache.GasUsage do
  @moduledoc """
  Cache for total gas usage.

  This module provides the `total/0` function which returns the total gas usage.
  It uses the incremental GasUsageCounter for efficient updates.
  Falls back to an estimate based on transaction count when counter is not initialized.
  """

  alias Explorer.Chain.Cache.GasUsageCounter
  alias Explorer.Chain.Cache.Helper

  # Average gas per transaction estimate (used for fallback)
  # Typical EVM transactions range from 21,000 (simple transfer) to 100,000+ (contract calls)
  @avg_gas_per_tx 65_000

  @spec total() :: non_neg_integer()
  def total do
    count = GasUsageCounter.total()

    # Fall back to estimate based on transaction count if counter is 0
    if count == 0 do
      tx_estimate = Helper.estimated_count_from("transactions")
      max(tx_estimate * @avg_gas_per_tx, 0)
    else
      count
    end
  end
end
