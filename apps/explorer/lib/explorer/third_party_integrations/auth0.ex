defmodule Explorer.ThirdPartyIntegrations.Auth0 do
  @moduledoc """
    Module for fetching jwt Auth0 Management API (https://auth0.com/docs/api/management/v2) jwt
  """
  @redis_key "auth0"

  @doc """
    Function responsible for retrieving machine to machine JWT for interacting with Auth0 Management API.
    Firstly it tries to access cached token and if there is no cached one, token will be requested from Auth0
  """
  @spec get_m2m_jwt() :: nil | String.t()
  def get_m2m_jwt do
    get_m2m_jwt_inner(Redix.command(:redix, ["GET", cookie_key(@redis_key)]))
  end

  def get_m2m_jwt_inner({:ok, token}) when not is_nil(token) do
    record_cache_metrics(:hit)
    token
  end

  def get_m2m_jwt_inner(_) do
    record_cache_metrics(:miss)
    start_time = System.monotonic_time(:microsecond)

    config = Application.get_env(:ueberauth, Ueberauth.Strategy.Auth0.OAuth)

    body = %{
      "client_id" => config[:client_id],
      "client_secret" => config[:client_secret],
      "audience" => "https://#{config[:domain]}/api/v2/",
      "grant_type" => "client_credentials"
    }

    headers = [{"Content-type", "application/json"}]

    result =
      case HTTPoison.post("https://#{config[:domain]}/oauth/token", Jason.encode!(body), headers, []) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          case Jason.decode!(body) do
            %{"access_token" => token, "expires_in" => ttl} ->
              cache_token(token, ttl - 1)

            _ ->
              nil
          end

        _ ->
          nil
      end

    duration = (System.monotonic_time(:microsecond) - start_time) / 1_000_000
    status = if is_nil(result), do: :error, else: :success
    record_api_metrics(duration, status)
    result
  end

  @doc """
    Generates key from chain_id and cookie hash for storing in Redis
  """
  @spec cookie_key(binary) :: String.t()
  def cookie_key(hash) do
    chain_id = Application.get_env(:block_scout_web, :chain_id)

    if chain_id do
      chain_id <> "_" <> hash
    else
      hash
    end
  end

  defp cache_token(token, ttl) do
    Redix.command(:redix, ["SET", cookie_key(@redis_key), token, "EX", ttl])
    token
  end

  # =============================================================================
  # Metrics Helper Functions
  # =============================================================================

  defp record_api_metrics(duration_seconds, status) do
    alias Explorer.Prometheus.Instrumenter

    if Code.ensure_loaded?(Instrumenter) do
      try do
        Instrumenter.external_api_request(:auth0, duration_seconds, status)
      rescue
        _ -> :ok
      end
    end
  end

  defp record_cache_metrics(result) do
    alias Explorer.Prometheus.Instrumenter

    if Code.ensure_loaded?(Instrumenter) do
      try do
        Instrumenter.external_api_cache(:auth0, result)
      rescue
        _ -> :ok
      end
    end
  end
end
