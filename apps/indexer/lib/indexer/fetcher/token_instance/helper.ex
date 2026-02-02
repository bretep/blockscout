defmodule Indexer.Fetcher.TokenInstance.Helper do
  @moduledoc """
    Common functions for Indexer.Fetcher.TokenInstance fetchers
  """
  require Logger

  alias Explorer.Chain
  alias Explorer.SmartContract.Reader
  alias Indexer.Fetcher.TokenInstance.MetadataRetriever

  @cryptokitties_address_hash "0x06012c8cf97bead5deae237070f9587f8e7a266d"

  @token_uri "c87b56dd"
  @uri "0e89341c"

  @erc_721_1155_abi [
    %{
      "type" => "function",
      "stateMutability" => "view",
      "payable" => false,
      "outputs" => [
        %{"type" => "string", "name" => ""}
      ],
      "name" => "tokenURI",
      "inputs" => [
        %{
          "type" => "uint256",
          "name" => "_tokenId"
        }
      ],
      "constant" => true
    },
    %{
      "type" => "function",
      "stateMutability" => "view",
      "payable" => false,
      "outputs" => [
        %{
          "type" => "string",
          "name" => "",
          "internalType" => "string"
        }
      ],
      "name" => "uri",
      "inputs" => [
        %{
          "type" => "uint256",
          "name" => "_id",
          "internalType" => "uint256"
        }
      ],
      "constant" => true
    }
  ]

  @spec batch_fetch_instances([%{}]) :: list()
  def batch_fetch_instances(token_instances) do
    # Log batch size for debugging
    Logger.debug("TokenInstance.Helper: batch_fetch_instances called with #{length(token_instances)} instances")

    token_instances =
      token_instances
      |> Enum.map(fn
        %{contract_address_hash: hash, token_id: token_id} -> {hash, token_id}
        {_, _} = tuple -> tuple
      end)
      # Filter out any entries with nil values to prevent insert failures
      |> Enum.filter(fn
        {nil, token_id} ->
          Logger.error("[TOKEN_INSTANCE_NIL_BUG] Input has nil contract_address_hash, token_id: #{inspect(token_id)}")
          false
        {contract_address_hash, nil} ->
          Logger.error("[TOKEN_INSTANCE_NIL_BUG] Input has nil token_id, contract_address_hash: #{inspect(contract_address_hash)}")
          false
        _ ->
          true
      end)

    splitted =
      Enum.group_by(token_instances, fn {contract_address_hash, _token_id} ->
        to_string(contract_address_hash) == @cryptokitties_address_hash
      end)

    cryptokitties =
      (splitted[true] || [])
      |> Enum.map(fn {contract_address_hash, token_id} ->
        {{:ok, ["https://api.cryptokitties.co/kitties/{id}"]}, to_string(token_id), contract_address_hash, token_id}
      end)

    other = splitted[false] || []

    token_types_map =
      Enum.reduce(other, %{}, fn {contract_address_hash, _token_id}, acc ->
        address_hash_string = to_string(contract_address_hash)

        Map.put_new(acc, address_hash_string, Chain.get_token_type(contract_address_hash))
      end)

    # Build RPC requests and get results
    rpc_requests =
      other
      |> Enum.map(fn {contract_address_hash, token_id} ->
        token_id = prepare_token_id(token_id)
        contract_address_hash_string = to_string(contract_address_hash)
        prepare_request(token_types_map[contract_address_hash_string], contract_address_hash_string, token_id)
      end)

    rpc_results = Reader.query_contracts(rpc_requests, @erc_721_1155_abi, [], false)

    # Log if RPC results count differs from input count
    if length(rpc_results) != length(other) do
      Logger.error(
        "[TOKEN_INSTANCE_NIL_BUG] RPC result count mismatch! other=#{length(other)}, rpc_results=#{length(rpc_results)}"
      )
    end

    # Build contract_results by zipping RPC results with original data
    contract_results_from_rpc =
      rpc_results
      |> Enum.zip_reduce(other, [], fn result, {contract_address_hash, token_id}, acc ->
        token_id = prepare_token_id(token_id)

        [
          {result, normalize_token_id(token_types_map[to_string(contract_address_hash)], token_id),
           contract_address_hash, token_id}
          | acc
        ]
      end)
      |> Enum.reverse()

    contract_results = contract_results_from_rpc ++ cryptokitties

    # Log contract_results to verify data integrity
    Enum.each(contract_results, fn {_result, _normalized_token_id, contract_address_hash, token_id} ->
      if is_nil(contract_address_hash) or is_nil(token_id) do
        Logger.error(
          "[TOKEN_INSTANCE_NIL_BUG] nil in contract_results! contract_address_hash=#{inspect(contract_address_hash)}, token_id=#{inspect(token_id)}"
        )
      end
    end)

    # Spawn tasks for metadata fetching
    tasks =
      contract_results
      |> Enum.map(fn {result, normalized_token_id, _contract_address_hash, _token_id} ->
        Task.async(fn -> MetadataRetriever.fetch_json(result, normalized_token_id) end)
      end)

    task_results = Task.yield_many(tasks, :infinity)

    # Log if task results count differs from contract_results count
    if length(task_results) != length(contract_results) do
      Logger.error(
        "[TOKEN_INSTANCE_NIL_BUG] Task result count mismatch! contract_results=#{length(contract_results)}, task_results=#{length(task_results)}"
      )
    end

    # Zip task results with contract_results and build insert params
    zipped = Enum.zip(task_results, contract_results)

    zipped
    |> Enum.map(fn {{_task, res}, {_result, _normalized_token_id, contract_address_hash, token_id}} ->
      # Log if we're about to use nil values
      if is_nil(contract_address_hash) or is_nil(token_id) do
        Logger.error(
          "[TOKEN_INSTANCE_NIL_BUG] nil in zipped result! contract_address_hash=#{inspect(contract_address_hash)}, token_id=#{inspect(token_id)}, res=#{inspect(res)}"
        )
      end

      case res do
        {:ok, result} ->
          result_to_insert_params(result, contract_address_hash, token_id)

        {:exit, reason} ->
          result_to_insert_params(
            {:error, MetadataRetriever.truncate_error("Terminated:" <> inspect(reason))},
            contract_address_hash,
            token_id
          )
      end
    end)
    # Filter out any results with nil PKs before upserting
    |> Enum.split_with(fn params ->
      case params do
        %{token_id: nil} -> false
        %{token_contract_address_hash: nil} -> false
        _ -> true
      end
    end)
    |> then(fn {valid, invalid} ->
      # Log a clear signal when nils are filtered - this is what to grep for
      if invalid != [] do
        Logger.error(
          "[TOKEN_INSTANCE_NIL_BUG] Filtered #{length(invalid)} records with nil PKs. " <>
          "Check logs above for details. Sample: #{inspect(Enum.take(invalid, 2))}"
        )
      end
      valid
    end)
    |> Chain.upsert_token_instances_list()
  end

  defp prepare_token_id(%Decimal{} = token_id), do: Decimal.to_integer(token_id)
  defp prepare_token_id(token_id), do: token_id

  defp prepare_request("ERC-721", contract_address_hash_string, token_id) do
    %{
      contract_address: contract_address_hash_string,
      method_id: @token_uri,
      args: [token_id],
      block_number: nil
    }
  end

  defp prepare_request(_token_type, contract_address_hash_string, token_id) do
    %{
      contract_address: contract_address_hash_string,
      method_id: @uri,
      args: [token_id],
      block_number: nil
    }
  end

  defp normalize_token_id("ERC-721", _token_id), do: nil

  defp normalize_token_id(_token_type, token_id),
    do: token_id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

  defp result_to_insert_params({:ok, %{metadata: metadata}}, token_contract_address_hash, token_id) do
    %{
      token_id: token_id,
      token_contract_address_hash: token_contract_address_hash,
      metadata: metadata,
      error: nil
    }
  end

  defp result_to_insert_params({:error_code, code}, token_contract_address_hash, token_id),
    do: token_instance_map_with_error(token_id, token_contract_address_hash, "request error: #{code}")

  defp result_to_insert_params({:error, reason}, token_contract_address_hash, token_id),
    do: token_instance_map_with_error(token_id, token_contract_address_hash, reason)

  defp token_instance_map_with_error(token_id, token_contract_address_hash, error) do
    %{
      token_id: token_id,
      token_contract_address_hash: token_contract_address_hash,
      error: error
    }
  end
end
