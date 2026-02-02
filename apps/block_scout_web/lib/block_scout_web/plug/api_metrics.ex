defmodule BlockScoutWeb.Plug.ApiMetrics do
  @moduledoc """
  Plug that tracks API request metrics via Prometheus.

  Tracks:
  - Request count by endpoint, method, and status
  - Request duration by endpoint
  - Active requests gauge

  ## Usage

      plug BlockScoutWeb.Plug.ApiMetrics, application: :api_v2

  ## Endpoint Normalization

  Endpoints are normalized to avoid high-cardinality labels:
  - `/v2/addresses/0x123.../transactions` -> `/v2/addresses/:address_hash/transactions`
  - `/v2/transactions/0xabc.../logs` -> `/v2/transactions/:tx_hash/logs`
  """

  require Logger
  alias Plug.Conn
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    start_time = System.monotonic_time(:microsecond)
    application = Keyword.get(opts, :application, :api)

    # Increment active requests
    endpoint = normalize_endpoint(conn.request_path)
    record_request_started(endpoint)

    # Store start time in conn private for use by other plugs (e.g., GraphQL metrics)
    conn = Conn.put_private(conn, :request_start_time, start_time)

    Conn.register_before_send(conn, fn conn ->
      duration = (System.monotonic_time(:microsecond) - start_time) / 1_000_000
      status = conn.status
      method = conn.method

      # Record metrics
      record_request_completed(application, endpoint, method, status, duration)

      conn
    end)
  end

  # =============================================================================
  # Endpoint Normalization
  # =============================================================================

  @doc """
  Normalize endpoint paths to avoid high-cardinality labels.
  Replaces dynamic segments (hashes, numbers) with placeholders.
  """
  def normalize_endpoint(path) when is_binary(path) do
    path
    |> String.split("/")
    |> Enum.map(&normalize_segment/1)
    |> Enum.join("/")
  end

  # Normalize individual path segments
  defp normalize_segment(""), do: ""

  # Ethereum address (0x followed by 40 hex chars)
  defp normalize_segment(<<"0x", rest::binary>>) when byte_size(rest) >= 40 do
    if String.match?(rest, ~r/^[0-9a-fA-F]{40,64}$/) do
      ":hash"
    else
      "0x#{rest}"
    end
  end

  # Transaction/block hash (64 hex chars without 0x)
  defp normalize_segment(segment) when byte_size(segment) == 64 do
    if String.match?(segment, ~r/^[0-9a-fA-F]+$/) do
      ":hash"
    else
      segment
    end
  end

  # Numeric ID (block number, token ID, etc.)
  defp normalize_segment(segment) do
    if String.match?(segment, ~r/^\d+$/) do
      ":id"
    else
      segment
    end
  end

  # =============================================================================
  # Metrics Recording
  # =============================================================================

  defp record_request_started(endpoint) do
    if instrumenter_loaded?() do
      try do
        BlockScoutWeb.Prometheus.ApiInstrumenter.api_request_started(endpoint)
      rescue
        _ -> :ok
      end
    end
  end

  defp record_request_completed(application, endpoint, method, status, duration) do
    if instrumenter_loaded?() do
      try do
        status_class = status_to_class(status)
        BlockScoutWeb.Prometheus.ApiInstrumenter.api_request_completed(
          application,
          endpoint,
          method,
          status_class,
          duration
        )
      rescue
        _ -> :ok
      end
    end
  end

  defp status_to_class(status) when is_integer(status) do
    cond do
      status >= 200 and status < 300 -> "2xx"
      status >= 300 and status < 400 -> "3xx"
      status >= 400 and status < 500 -> "4xx"
      status >= 500 -> "5xx"
      true -> "other"
    end
  end

  defp status_to_class(_), do: "other"

  defp instrumenter_loaded? do
    Code.ensure_loaded?(BlockScoutWeb.Prometheus.ApiInstrumenter)
  end
end
