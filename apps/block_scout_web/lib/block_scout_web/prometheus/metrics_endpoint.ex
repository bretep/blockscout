defmodule BlockScoutWeb.Prometheus.MetricsEndpoint do
  @moduledoc """
  Separate endpoint for Prometheus metrics on a dedicated port.

  This keeps metrics internal and not exposed on the public API port.
  Configure the port with METRICS_PORT environment variable (default: 9567).
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/metrics" do
    metrics = Prometheus.Format.Text.format()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end

  get "/health" do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "OK")
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  @doc """
  Returns child spec for starting the metrics server.
  """
  def child_spec(_opts) do
    port = metrics_port()

    %{
      id: __MODULE__,
      start: {Plug.Cowboy, :http, [__MODULE__, [], [port: port]]},
      type: :worker,
      restart: :permanent
    }
  end

  defp metrics_port do
    case System.get_env("METRICS_PORT") do
      nil -> 9567
      port -> String.to_integer(port)
    end
  end
end
