defmodule EthereumJSONRPC.HTTP.Finch do
  @moduledoc """
  Uses `Finch` for `EthereumJSONRPC.HTTP`.
  Finch handles large responses (100MB+) better than hackney.
  """

  alias EthereumJSONRPC.HTTP

  @behaviour HTTP
  @finch_name EthereumJSONRPC.Finch

  @impl HTTP
  def json_rpc(url, json, headers, options) when is_binary(url) and is_list(options) do
    timeout = Keyword.get(options, :timeout, 60_000)
    recv_timeout = Keyword.get(options, :recv_timeout, 60_000)

    request =
      Finch.build(
        :post,
        url,
        headers,
        json
      )

    case Finch.request(request, @finch_name, receive_timeout: recv_timeout, pool_timeout: timeout) do
      {:ok, %Finch.Response{status: status_code, body: body}} ->
        {:ok, %{body: body, status_code: status_code}}

      {:error, %Mint.TransportError{reason: reason}} ->
        {:error, reason}

      {:error, %Finch.Error{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def json_rpc(url, _json, _headers, _options) when is_nil(url), do: {:error, "URL is nil"}
end
