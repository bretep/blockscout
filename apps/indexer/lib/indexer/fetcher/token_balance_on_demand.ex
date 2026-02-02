defmodule Indexer.Fetcher.TokenBalanceOnDemand do
  @moduledoc """
  Ensures that we have a reasonably up to date address tokens balance.

  """

  use Indexer.Fetcher

  alias Explorer.{Chain, Repo}
  alias Explorer.Chain.Address.CurrentTokenBalance
  alias Explorer.Chain.Cache.BlockNumber
  alias Explorer.Chain.Events.Publisher
  alias Explorer.Chain.Hash
  alias Explorer.Counters.AverageBlockTime
  alias Explorer.Token.BalanceReader
  alias Timex.Duration

  require Logger

  ## Interface

  @spec trigger_fetch(Hash.t()) :: :ok
  def trigger_fetch(address_hash) do
    latest_block_number = latest_block_number()

    case stale_balance_window(latest_block_number) do
      {:error, _} ->
        :current

      stale_balance_window ->
        do_trigger_fetch(address_hash, latest_block_number, stale_balance_window)
    end
  end

  @spec trigger_historic_fetch(
          Hash.t(),
          Hash.t(),
          String.t(),
          Decimal.t() | nil,
          non_neg_integer()
        ) :: {:ok, pid}
  def trigger_historic_fetch(address_hash, contract_address_hash, token_type, token_id, block_number) do
    Task.start(fn ->
      do_trigger_historic_fetch(address_hash, contract_address_hash, token_type, token_id, block_number)
    end)
  end

  ## Implementation

  defp do_trigger_fetch(address_hash, latest_block_number, stale_balance_window)
       when not is_nil(address_hash) do
    stale_current_token_balances =
      address_hash
      |> Chain.fetch_last_token_balances_include_unfetched()
      |> delete_invalid_balances()
      |> Enum.filter(fn current_token_balance -> current_token_balance.block_number < stale_balance_window end)

    if Enum.count(stale_current_token_balances) > 0 do
      start_time = System.monotonic_time(:microsecond)
      staleness = latest_block_number - Enum.min_by(stale_current_token_balances, & &1.block_number).block_number

      fetch_and_update(latest_block_number, address_hash, stale_current_token_balances)

      duration = (System.monotonic_time(:microsecond) - start_time) / 1_000_000
      record_fetch_metrics(:token_balance, duration, :success, staleness)
    else
      record_fetch_metrics(:token_balance, 0, :skipped, nil)
      :current
    end

    :ok
  end

  defp delete_invalid_balances(current_token_balances) do
    {invalid_balances, valid_balances} = Enum.split_with(current_token_balances, &is_nil(&1.token_type))
    Enum.each(invalid_balances, &Repo.delete/1)
    valid_balances
  end

  defp fetch_and_update(block_number, address_hash, stale_current_token_balances) do
    %{erc_1155: erc_1155_ctbs, other: other_ctbs, tokens: tokens} =
      stale_current_token_balances
      |> Enum.reduce(%{erc_1155: [], other: [], tokens: %{}}, fn %{token_id: token_id} = stale_current_token_balance,
                                                                 acc ->
        prepared_ctb = %{
          token_contract_address_hash:
            "0x" <> Base.encode16(stale_current_token_balance.token.contract_address_hash.bytes),
          address_hash: "0x" <> Base.encode16(address_hash.bytes),
          block_number: block_number,
          token_id: token_id && Decimal.to_integer(token_id),
          token_type: stale_current_token_balance.token_type
        }

        updated_tokens =
          Map.put_new(
            acc[:tokens],
            stale_current_token_balance.token.contract_address_hash.bytes,
            stale_current_token_balance.token
          )

        result =
          if stale_current_token_balance.token_type == "ERC-1155" do
            Map.put(acc, :erc_1155, [prepared_ctb | acc[:erc_1155]])
          else
            Map.put(acc, :other, [prepared_ctb | acc[:other]])
          end

        Map.put(result, :tokens, updated_tokens)
      end)

    erc_1155_ctbs_reversed = Enum.reverse(erc_1155_ctbs)
    other_ctbs_reversed = Enum.reverse(other_ctbs)

    updated_erc_1155_ctbs =
      if Enum.count(erc_1155_ctbs_reversed) > 0 do
        erc_1155_ctbs_reversed
        |> BalanceReader.get_balances_of_erc_1155()
        |> Enum.zip(erc_1155_ctbs_reversed)
        |> Enum.map(&prepare_updated_balance(&1, block_number))
      else
        []
      end

    updated_other_ctbs =
      if Enum.count(other_ctbs_reversed) > 0 do
        other_ctbs_reversed
        |> BalanceReader.get_balances_of()
        |> Enum.zip(other_ctbs_reversed)
        |> Enum.map(&prepare_updated_balance(&1, block_number))
      else
        []
      end

    filtered_current_token_balances_update_params =
      (updated_erc_1155_ctbs ++ updated_other_ctbs)
      |> Enum.filter(&(!is_nil(&1)))

    imported_ctbs =
      case Chain.import(%{
             address_current_token_balances: %{
               params: filtered_current_token_balances_update_params
             },
             broadcast: false
           }) do
        {:ok, %{address_current_token_balances: ctbs}} -> ctbs
        {:ok, %{}} -> []
      end

    Publisher.broadcast(
      %{
        address_current_token_balances: %{
          address_hash: to_string(address_hash),
          address_current_token_balances:
            imported_ctbs
            |> Enum.map(fn ctb -> %CurrentTokenBalance{ctb | token: tokens[ctb.token_contract_address_hash.bytes]} end)
        }
      },
      :on_demand
    )
  end

  defp prepare_updated_balance({{:ok, updated_balance}, stale_current_token_balance}, block_number) do
    %{}
    |> Map.put(:address_hash, stale_current_token_balance.address_hash)
    |> Map.put(:token_contract_address_hash, stale_current_token_balance.token_contract_address_hash)
    |> Map.put(:token_type, stale_current_token_balance.token_type)
    |> Map.put(:token_id, stale_current_token_balance.token_id)
    |> Map.put(:block_number, block_number)
    |> Map.put(:value, Decimal.new(updated_balance))
    |> Map.put(:value_fetched_at, DateTime.utc_now())
  end

  defp prepare_updated_balance({{:error, error}, _ctb}, _block_number) do
    Logger.warn(fn -> ["Error on updating current token balance: ", inspect(error)] end)
    nil
  end

  defp do_trigger_historic_fetch(address_hash, contract_address_hash, token_type, token_id, block_number) do
    start_time = System.monotonic_time(:microsecond)

    request = %{
      token_contract_address_hash: to_string(contract_address_hash),
      address_hash: to_string(address_hash),
      block_number: block_number,
      token_id: token_id && Decimal.to_integer(token_id)
    }

    balance_response =
      case token_type do
        "ERC-1155" -> BalanceReader.get_balances_of_erc_1155([request])
        _ -> BalanceReader.get_balances_of([request])
      end

    balance = balance_response[:ok]

    result =
      if balance do
        %{
          address_token_balances: %{
            params: [
              %{
                address_hash: address_hash,
                token_contract_address_hash: contract_address_hash,
                token_type: token_type,
                token_id: token_id,
                block_number: block_number,
                value: Decimal.new(balance),
                value_fetched_at: DateTime.utc_now()
              }
            ]
          },
          broadcast: :on_demand
        }
        |> Chain.import()
      else
        {:error, :no_balance}
      end

    duration = (System.monotonic_time(:microsecond) - start_time) / 1_000_000
    status = if match?({:ok, _}, result), do: :success, else: :error
    record_fetch_metrics(:token_balance_historic, duration, status, nil)

    result
  end

  defp latest_block_number do
    BlockNumber.get_max()
  end

  defp stale_balance_window(block_number) do
    case AverageBlockTime.average_block_time() do
      {:error, :disabled} ->
        fallback_threshold_in_blocks = Application.get_env(:indexer, __MODULE__)[:fallback_threshold_in_blocks]
        block_number - fallback_threshold_in_blocks

      duration ->
        average_block_time =
          duration
          |> Duration.to_milliseconds()
          |> round()

        if average_block_time == 0 do
          {:error, :empty_database}
        else
          threshold = Application.get_env(:indexer, __MODULE__)[:threshold]
          block_number - div(threshold, average_block_time)
        end
    end
  end

  defp record_fetch_metrics(fetch_type, duration_seconds, status, staleness_blocks) do
    alias Indexer.Prometheus.Instrumenter

    if Code.ensure_loaded?(Instrumenter) do
      try do
        Instrumenter.on_demand_fetch(fetch_type, duration_seconds, status, staleness_blocks)
      rescue
        _ -> :ok
      end
    end
  end
end
