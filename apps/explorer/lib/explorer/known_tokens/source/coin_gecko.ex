defmodule Explorer.KnownTokens.Source.CoinGecko do
  @moduledoc """
  Adapter for fetching known tokens from CoinGecko.
  """

  alias Explorer.KnownTokens.Source
  alias Explorer.Chain.Hash

  @behaviour Source

  @impl Source
  def format_data(data) do
    Enum.map(data, fn %{"id" => coin_id, "symbol" => symbol, "platforms" => platforms} ->
      %{
        id: coin_id,
        symbol: symbol,
        address_hash: if(platforms[platform()], do: Hash.Address.cast(platforms[platform()]), else: nil)
      }
    end)
  end

  @impl Source
  def source_url do
    "https://api.coingecko.com/api/v3/coins/list?include_platform=true"
  end

  @impl Sources
  def headers do
    [{"Content-Type", "application/json"}]
  end

  defp platform do
    Application.get_env(:explorer, __MODULE__, []) || "ethereum"
  end
end
