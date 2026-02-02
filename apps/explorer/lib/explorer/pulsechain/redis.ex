defmodule Explorer.PulseChain.Redis do
  @moduledoc """
    PulseChain module for replacing postgres LISTEN/NOTIFY
  """
  @redis_key "pulsechain"

  @doc """
    Function responsible for retrieving machine to machine JWT for interacting with Auth0 Management API.
    Firstly it tries to access cached token and if there is no cached one, token will be requested from Auth0
  """
  @spec get_m2m_jwt() :: nil | String.t()
  def get_m2m_jwt, do: get_m2m_jwt_inner(Redix.command(:redix, ["GET", @redis_key]))

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
    status = if result, do: :success, else: :error
    record_auth0_metrics(duration, status)
    result
  end

  defp cache_token(token, ttl) do
    chain_id = Application.get_env(:block_scout_web, :chain_id)
    Redix.command(:redix, ["SET", "#{chain_id}_#{@redis_key}", token, "EX", ttl])
    token
  end

  # =============================================================================
  # Metrics Helper Functions
  # =============================================================================

  defp record_cache_metrics(result) do
    alias Explorer.Prometheus.Instrumenter

    if Code.ensure_loaded?(Instrumenter) do
      try do
        Instrumenter.external_api_cache(:auth0_m2m, result)
      rescue
        _ -> :ok
      end
    end
  end

  defp record_auth0_metrics(duration_seconds, status) do
    alias Explorer.Prometheus.Instrumenter

    if Code.ensure_loaded?(Instrumenter) do
      try do
        Instrumenter.external_api_request(:auth0, duration_seconds, status)
      rescue
        _ -> :ok
      end
    end
  end
end
