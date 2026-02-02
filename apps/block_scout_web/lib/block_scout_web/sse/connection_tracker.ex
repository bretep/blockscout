defmodule BlockScoutWeb.SSE.ConnectionTracker do
  @moduledoc """
  Tracks SSE connections and ensures metrics are properly decremented when
  handler processes die.

  When a client disconnects, Cowboy terminates the handler process without
  giving it a chance to run cleanup code. This GenServer monitors all SSE
  handler processes and decrements the connection counter when they exit.

  Usage:
    # In SSE handler, after opening connection:
    ConnectionTracker.track(self(), "blocks")

    # When handler process dies (any reason), this GenServer receives {:DOWN, ...}
    # and automatically decrements sse_connections_active for that endpoint.
  """

  use GenServer
  require Logger

  alias BlockScoutWeb.Prometheus.SSEInstrumenter

  @table_name :sse_connection_tracker

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Track an SSE connection. Call this from the handler process after opening
  the connection. When the handler process dies (for any reason), the
  connection counter will be automatically decremented.
  """
  @spec track(pid(), String.t()) :: :ok
  def track(pid, endpoint) when is_pid(pid) and is_binary(endpoint) do
    GenServer.cast(__MODULE__, {:track, pid, endpoint})
  end

  @doc """
  Get the number of tracked connections (for debugging).
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table_name, :size)
  rescue
    ArgumentError -> 0
  end

  @doc """
  Get all tracked connections (for debugging).
  """
  @spec list() :: [{pid(), String.t(), reference()}]
  def list do
    :ets.tab2list(@table_name)
  rescue
    ArgumentError -> []
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Create ETS table to store {pid, endpoint, monitor_ref}
    # Using ETS allows us to efficiently look up by monitor ref when DOWN arrives
    table = :ets.new(@table_name, [:named_table, :set, :protected])
    Logger.info("[SSE.ConnectionTracker] Started, tracking SSE connections for proper cleanup")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:track, pid, endpoint}, state) do
    # Monitor the handler process
    ref = Process.monitor(pid)

    # Store in ETS: key is monitor ref (for efficient lookup in handle_info)
    :ets.insert(@table_name, {ref, pid, endpoint})

    Logger.debug("[SSE.ConnectionTracker] Tracking #{endpoint} connection from #{inspect(pid)}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    # Handler process died - find and clean up the connection
    case :ets.lookup(@table_name, ref) do
      [{^ref, ^pid, endpoint}] ->
        # Delete from tracking table
        :ets.delete(@table_name, ref)

        # Decrement the Prometheus gauge
        SSEInstrumenter.sse_connection_closed(endpoint, normalize_reason(reason))

        Logger.info(
          "[SSE.ConnectionTracker] Connection closed: endpoint=#{endpoint}, " <>
            "pid=#{inspect(pid)}, reason=#{inspect(reason)}"
        )

      [] ->
        # Already cleaned up or wasn't tracked
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("[SSE.ConnectionTracker] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Convert exit reasons to simple strings for metrics labels
  defp normalize_reason(:normal), do: "normal"
  defp normalize_reason(:shutdown), do: "shutdown"
  defp normalize_reason({:shutdown, _}), do: "shutdown"
  defp normalize_reason(:killed), do: "killed"
  defp normalize_reason(:timeout), do: "timeout"
  defp normalize_reason({:timeout, _}), do: "timeout"
  defp normalize_reason(_), do: "error"
end
