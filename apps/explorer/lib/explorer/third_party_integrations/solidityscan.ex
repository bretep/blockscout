defmodule Explorer.ThirdPartyIntegrations.SolidityScan do
  @moduledoc """
  Module for SolidityScan integration https://apidoc.solidityscan.com/solidityscan-security-api/solidityscan-other-apis/quickscan-api-v1
  """

  alias Explorer.Helper

  @blockscout_platform_id "16"
  @recv_timeout 60_000

  @doc """
  Proxy request to solidityscan API endpoint for the given smart-contract
  """
  @spec solidityscan_request(String.t()) :: any()
  def solidityscan_request(address_hash_string) do
    start_time = System.monotonic_time(:microsecond)
    headers = [{"Authorization", "Token #{api_key()}"}]

    url = base_url(address_hash_string)

    result =
      case HTTPoison.get(url, headers, recv_timeout: @recv_timeout) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          Helper.decode_json(body)

        _ ->
          nil
      end

    duration = (System.monotonic_time(:microsecond) - start_time) / 1_000_000
    status = if is_nil(result), do: :error, else: :success
    record_api_metrics(duration, status)
    result
  end

  defp base_url(address_hash_string) do
    "https://api.solidityscan.com/api/v1/quickscan/#{@blockscout_platform_id}/#{chain_id()}/#{address_hash_string}"
  end

  defp chain_id do
    Application.get_env(:explorer, __MODULE__)[:chain_id]
  end

  defp api_key do
    Application.get_env(:explorer, __MODULE__)[:api_key]
  end

  # =============================================================================
  # Metrics Helper Functions
  # =============================================================================

  defp record_api_metrics(duration_seconds, status) do
    alias Explorer.Prometheus.Instrumenter

    if Code.ensure_loaded?(Instrumenter) do
      try do
        Instrumenter.external_api_request(:solidityscan, duration_seconds, status)
      rescue
        _ -> :ok
      end
    end
  end
end
