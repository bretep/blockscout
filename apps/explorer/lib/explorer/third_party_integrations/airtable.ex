defmodule Explorer.ThirdPartyIntegrations.AirTable do
  @moduledoc """
    Module is responsible for submitting requests for public tags to AirTable
  """
  require Logger

  alias Ecto.Changeset
  alias Explorer.Account.PublicTagsRequest
  alias Explorer.Repo
  alias HTTPoison.Response

  def submit({:ok, %PublicTagsRequest{} = new_request} = input) do
    if Mix.env() == :test do
      new_request
      |> PublicTagsRequest.changeset(%{request_id: "123"})
      |> Repo.account_repo().update()

      input
    else
      api_key = Application.get_env(:explorer, __MODULE__)[:api_key]
      headers = [{"Authorization", "Bearer #{api_key}"}, {"Content-Type", "application/json"}]
      url = Application.get_env(:explorer, __MODULE__)[:table_url]

      body = %{
        "typecast" => true,
        "records" => [%{"fields" => PublicTagsRequest.to_map(new_request)}]
      }

      start_time = System.monotonic_time(:microsecond)
      request = HTTPoison.post(url, Jason.encode!(body), headers, [])
      duration = (System.monotonic_time(:microsecond) - start_time) / 1_000_000

      case request do
        {:ok, %Response{body: body, status_code: 200}} ->
          record_airtable_metrics(duration, :success)

          request_id = Enum.at(Jason.decode!(body)["records"], 0)["fields"]["request_id"]

          new_request
          |> PublicTagsRequest.changeset(%{request_id: request_id})
          |> Repo.account_repo().update()

          input

        error ->
          record_airtable_metrics(duration, :error)
          Logger.error(fn -> ["Error while submitting AirTable entry", inspect(error)] end)

          {:error,
           %{
             (%PublicTagsRequest{}
              |> PublicTagsRequest.changeset_without_constraints(PublicTagsRequest.to_map(new_request))
              |> Changeset.add_error(:full_name, "AirTable error. Please try again later"))
             | action: :insert
           }}
      end
    end
  end

  def submit(error), do: error

  # =============================================================================
  # Metrics Helper Functions
  # =============================================================================

  defp record_airtable_metrics(duration_seconds, status) do
    alias Explorer.Prometheus.Instrumenter

    if Code.ensure_loaded?(Instrumenter) do
      try do
        Instrumenter.external_api_request(:airtable, duration_seconds, status)
      rescue
        _ -> :ok
      end
    end
  end
end
