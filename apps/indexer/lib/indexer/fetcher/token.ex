defmodule Indexer.Fetcher.Token do
  @moduledoc """
  Fetches information about a token.
  """

  use Indexer.Fetcher, restart: :permanent
  use Spandex.Decorators

  alias Explorer.Chain
  alias Explorer.Chain.Hash.Address
  alias Explorer.Chain.Token
  alias Explorer.Token.MetadataRetriever
  alias Indexer.{BufferedTask, Tracer}

  @behaviour BufferedTask

  @default_max_concurrency 10

  @doc false
  def child_spec([init_options, gen_server_options]) do
    {state, mergeable_init_options} = Keyword.pop(init_options, :json_rpc_named_arguments)

    unless state do
      raise ArgumentError,
            ":json_rpc_named_arguments must be provided to `#{__MODULE__}.child_spec " <>
              "to allow for json_rpc calls when running."
    end

    merged_init_opts =
      defaults()
      |> Keyword.merge(mergeable_init_options)
      |> Keyword.put(:state, state)

    Supervisor.child_spec({BufferedTask, [{__MODULE__, merged_init_opts}, gen_server_options]}, id: __MODULE__)
  end

  @impl BufferedTask
  def init(initial_acc, reducer, _) do
    {:ok, acc} =
      Chain.stream_uncataloged_token_contract_address_hashes(
        initial_acc,
        fn address, acc ->
          reducer.(address, acc)
        end,
        true
      )

    acc
  end

  @impl BufferedTask
  @decorate trace(name: "fetch", resource: "Indexer.Fetcher.Token.run/2", service: :indexer, tracer: Tracer)
  def run([token_contract_address], _json_rpc_named_arguments) do
    start_time = System.monotonic_time(:microsecond)
    options = [necessity_by_association: %{[contract_address: :smart_contract] => :optional}]

    result =
      case Chain.token_from_address_hash(token_contract_address, options) do
        {:ok, %Token{} = token} ->
          catalog_token(token)
      end

    duration = (System.monotonic_time(:microsecond) - start_time) / 1_000_000
    record_run_metrics(duration, result)
    result
  end

  @doc """
  Fetches token data asynchronously given a list of `t:Explorer.Chain.Token.t/0`s.
  """
  @spec async_fetch([Address.t()]) :: :ok
  def async_fetch(token_contract_addresses) do
    BufferedTask.buffer(__MODULE__, token_contract_addresses)
  end

  defp catalog_token(%Token{contract_address_hash: contract_address_hash} = token) do
    token_params =
      contract_address_hash
      |> MetadataRetriever.get_functions_of()
      |> Map.put(:cataloged, true)

    {:ok, _} = Chain.update_token(token, token_params)
    :ok
  end

  defp defaults do
    [
      flush_interval: 300,
      max_batch_size: 1,
      max_concurrency: Application.get_env(:indexer, __MODULE__)[:concurrency] || @default_max_concurrency,
      task_supervisor: Indexer.Fetcher.Token.TaskSupervisor
    ]
  end

  # =============================================================================
  # Metrics Helper Functions
  # =============================================================================

  defp record_run_metrics(duration_seconds, result) do
    alias Indexer.Prometheus.Instrumenter

    if Code.ensure_loaded?(Instrumenter) do
      try do
        Instrumenter.fetcher_run_duration(:token, duration_seconds)

        case result do
          :ok -> Instrumenter.fetcher_items_processed(:token, 1)
          _ -> Instrumenter.fetcher_error(:token, :catalog_error)
        end
      rescue
        _ -> :ok
      end
    end
  end
end
