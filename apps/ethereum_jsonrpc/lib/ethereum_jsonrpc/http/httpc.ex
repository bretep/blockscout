defmodule EthereumJSONRPC.HTTP.HTTPC do
  @moduledoc """
  Uses Erlang's built-in `:httpc` for `EthereumJSONRPC.HTTP`.
  This handles large responses (100MB+) better than hackney.
  """

  alias EthereumJSONRPC.HTTP

  @behaviour HTTP

  @impl HTTP
  def json_rpc(url, json, headers, options) when is_binary(url) and is_list(options) do
    # Ensure inets is started
    :inets.start()

    # Convert headers to charlists for :httpc
    httpc_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    # Build request
    request = {to_charlist(url), httpc_headers, ~c"application/json", json}

    # Extract timeout options
    timeout = Keyword.get(options, :timeout, 60_000)
    recv_timeout = Keyword.get(options, :recv_timeout, 60_000)

    http_options = [
      timeout: timeout,
      connect_timeout: recv_timeout
    ]

    httpc_options = [
      body_format: :binary
    ]

    case :httpc.request(:post, request, http_options, httpc_options) do
      {:ok, {{_http_version, status_code, _reason_phrase}, _headers, body}} ->
        {:ok, %{body: body, status_code: status_code}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def json_rpc(url, _json, _headers, _options) when is_nil(url), do: {:error, "URL is nil"}
end
