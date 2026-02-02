defmodule Explorer.Chain.Cache.Transaction do
  @moduledoc """
  Cache for estimated transaction count.

  This module provides the `estimated_count/0` function which returns the transaction count.
  It first checks the TransactionsCounter (incremental counter) and falls back to pg_class.reltuples.
  """

  alias Explorer.Chain.Cache.Helper
  alias Explorer.Chain.Cache.TransactionsCounter

  @doc """
  Estimated count of `t:Explorer.Chain.Transaction.t/0`.

  Returns the transaction count from the incremental TransactionsCounter if available,
  otherwise falls back to pg_class.reltuples estimate.
  """
  @spec estimated_count() :: non_neg_integer()
  def estimated_count do
    # First try the incremental counter (stored in last_fetched_counters table)
    count =
      case TransactionsCounter.fetch([]) do
        nil -> 0
        %Decimal{} = val -> Decimal.to_integer(val)
        val when is_integer(val) -> val
        val -> val |> Decimal.new() |> Decimal.to_integer()
      end

    # Fall back to pg_class.reltuples estimate if counter is 0 or nil
    if count == 0 do
      max(Helper.estimated_count_from("transactions"), 0)
    else
      count
    end
  end
end
