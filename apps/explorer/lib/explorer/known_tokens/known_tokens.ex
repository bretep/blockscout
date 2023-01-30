defmodule Explorer.KnownTokens do
  @moduledoc """
  Local cache for known tokens ids for CoinGecko. This fetches and exposes a mapping from contract
  address or from token symbol to a coin id. This data consumed by `Explorer.ExchangeRates.TokenExchangeRates` and
  `Explorer.ExchangeRates.Source.CoinGecko`.

  Data is updated every 1 hour.
  """

  use GenServer

  require Logger

  alias Explorer.Chain.Hash
  alias Explorer.KnownTokens.Source

  @interval :timer.hours(1)
  @address_to_coin_id_table_name :address_to_coin_gecko_coin_id
  @symbol_to_coin_id_table_name :symbol_to_coin_gecko_coin_id

  @impl GenServer
  def handle_info(:update, state) do
    IO.inspect("here??")
    Logger.debug(fn -> "Updating cached known tokens" end)

    fetch_known_tokens()

    {:noreply, state}
  end

  # Callback for successful fetch
  @impl GenServer
  def handle_info({_ref, {:ok, addresses}}, state) do
    if store() == :ets do
      {symbols_to_ids, addresses_to_ids} =
        Enum.reduce(
          addresses,
          fn
            %{coin_id: coin_id, symbol: symbol, address_hash: nil}, {symbols_to_ids_acc, addresses_to_ids_acc} ->
              {[{{symbol, coin_id}} | symbols_to_ids_acc], addresses_to_ids_acc}

            %{coin_id: coin_id, symbol: symbol, address_hash: address_hash},
            {symbols_to_ids_acc, addresses_to_ids_acc} ->
              {[{symbol, coin_id} | symbols_to_ids_acc], [{address_hash, coin_id} | addresses_to_ids_acc]}
          end
        )

      :ets.insert(symbol_to_coin_id_table_name(), symbols_to_ids)
      :ets.insert(address_to_coin_id_table_name(), addresses_to_ids)
    end

    {:noreply, state}
  end

  # Callback for errored fetch
  @impl GenServer
  def handle_info({_ref, {:error, reason}}, state) do
    Logger.warn(fn -> "Failed to get known tokens with reason '#{reason}'." end)

    fetch_known_tokens()

    {:noreply, state}
  end

  # Callback that a monitored process has shutdown
  @impl GenServer
  def handle_info({:DOWN, _, :process, _, _}, state) do
    {:noreply, state}
  end

  @impl GenServer
  def init(_) do
    send(self(), :update)
    :timer.send_interval(@interval, :update)

    table_opts = [
      :set,
      :named_table,
      :public,
      read_concurrency: true
    ]

    if store() == :ets do
      :ets.new(symbol_to_coin_id_table_name(), table_opts)
      :ets.new(address_to_coin_id_table_name(), table_opts)
    end

    {:ok, %{}}
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns a CoinGecko coin id for a given symbol or address hash
  """
  @spec lookup(String.t()) :: String.t() | nil
  def lookup(symbol) when is_binary(symbol) do
    if enabled?() and store() == :ets and ets_table_exists?(symbol_to_coin_id_table_name()) do
      case :ets.lookup(symbol_to_coin_id_table_name(), symbol) do
        [{_symbol, coin_id} | _] -> coin_id
        _ -> nil
      end
    end
  end

  @spec lookup(Hash.Address.t()) :: String.t() | nil
  def lookup(address_hash) do
    if enabled?() and store() == :ets and ets_table_exists?(address_to_coin_id_table_name()) do
      case :ets.lookup(address_to_coin_id_table_name(), address_hash) do
        [{_address_hash, coin_id} | _] -> coin_id
        _ -> nil
      end
    end
  end

  defp ets_table_exists?(table) do
    :ets.whereis(table) !== :undefined
  end

  @doc false
  @spec symbol_to_coin_id_table_name() :: atom()
  def symbol_to_coin_id_table_name do
    config(:symbol_to_coin_id_table_name) || @symbol_to_coin_id_table_name
  end

  @doc false
  @spec address_to_coin_id_table_name() :: atom()
  def address_to_coin_id_table_name do
    config(:address_to_coin_id_table_name) || @address_to_coin_id_table_name
  end

  @spec config(atom()) :: term
  defp config(key) do
    Application.get_env(:explorer, __MODULE__, [])[key]
  end

  @spec fetch_known_tokens :: Task.t()
  defp fetch_known_tokens do
    IO.inspect("here")
    Task.Supervisor.async_nolink(Explorer.MarketTaskSupervisor, fn ->
      IO.inspect("here")
      Source.fetch_known_tokens()
    end)
  end

  defp store do
    config(:store) || :ets
  end

  defp enabled? do
    Application.get_env(:explorer, __MODULE__, [])[:enabled] == true
  end
end
