defmodule Explorer.SmartContract.RustVerifierInterfaceBehaviour do
  @moduledoc """
    This behaviour module was created in order to add possibility to extend the functionality of RustVerifierInterface
  """
  defmacro __using__(_) do
    # credo:disable-for-next-line
    quote([]) do
      alias Explorer.Utility.RustService
      alias HTTPoison.Response
      require Logger

      @post_timeout :timer.minutes(5)
      @request_error_msg "Error while sending request to verification microservice"

      def verify_multi_part(
            %{
              "bytecode" => _,
              "bytecodeType" => _,
              "compilerVersion" => _,
              "sourceFiles" => _,
              "evmVersion" => _,
              "optimizationRuns" => _,
              "libraries" => _
            } = body,
            metadata
          ) do
        http_post_request(solidity_multiple_files_verification_url(), append_metadata(body, metadata), true)
      end

      def verify_standard_json_input(
            %{
              "bytecode" => _,
              "bytecodeType" => _,
              "compilerVersion" => _,
              "input" => _
            } = body,
            metadata
          ) do
        http_post_request(solidity_standard_json_verification_url(), append_metadata(body, metadata), true)
      end

      def vyper_verify_multipart(
            %{
              "bytecode" => _,
              "bytecodeType" => _,
              "compilerVersion" => _,
              "sourceFiles" => _
            } = body,
            metadata
          ) do
        http_post_request(vyper_multiple_files_verification_url(), append_metadata(body, metadata), true)
      end

      def vyper_verify_standard_json(
            %{
              "bytecode" => _,
              "bytecodeType" => _,
              "compilerVersion" => _,
              "input" => _
            } = body,
            metadata
          ) do
        http_post_request(vyper_standard_json_verification_url(), append_metadata(body, metadata), true)
      end

      def http_post_request(url, body, is_verification_request? \\ false) do
        headers = [{"Content-Type", "application/json"}]
        start_time = System.monotonic_time(:microsecond)
        endpoint = verification_endpoint_from_url(url)

        result =
          case HTTPoison.post(url, Jason.encode!(body), maybe_put_api_key_header(headers, is_verification_request?),
                 recv_timeout: @post_timeout
               ) do
            {:ok, %Response{body: body, status_code: _}} ->
              process_verifier_response(body)

            {:error, error} ->
              old_truncate = Application.get_env(:logger, :truncate)
              Logger.configure(truncate: :infinity)

              Logger.error(fn ->
                [
                  "Error while sending request to verification microservice url: #{url}, body: #{inspect(body, limit: :infinity, printable_limit: :infinity)}: ",
                  inspect(error, limit: :infinity, printable_limit: :infinity)
                ]
              end)

              Logger.configure(truncate: old_truncate)
              {:error, @request_error_msg}
          end

        duration = (System.monotonic_time(:microsecond) - start_time) / 1_000_000
        record_verification_metrics(endpoint, duration, result)

        result
      end

      defp verification_endpoint_from_url(url) when is_binary(url) do
        cond do
          String.contains?(url, "solidity/sources:verify-multi-part") -> :solidity_multi_part
          String.contains?(url, "solidity/sources:verify-standard-json") -> :solidity_standard_json
          String.contains?(url, "vyper/sources:verify-multi-part") -> :vyper_multi_part
          String.contains?(url, "vyper/sources:verify-standard-json") -> :vyper_standard_json
          String.contains?(url, "solidity/versions") -> :solidity_versions
          String.contains?(url, "vyper/versions") -> :vyper_versions
          true -> :unknown
        end
      end

      defp record_verification_metrics(endpoint, duration_seconds, result) do
        alias Explorer.Prometheus.Instrumenter

        if Code.ensure_loaded?(Instrumenter) do
          try do
            Instrumenter.verification_microservice_request(endpoint, duration_seconds)

            status = if match?({:ok, _}, result), do: :success, else: :failure
            Instrumenter.verification_request(endpoint, duration_seconds, status)

            case result do
              {:error, error} ->
                Instrumenter.verification_error(endpoint, error)

              _ ->
                :ok
            end
          rescue
            _ -> :ok
          end
        end
      end

      defp maybe_put_api_key_header(headers, false), do: headers

      defp maybe_put_api_key_header(headers, true) do
        api_key = Application.get_env(:explorer, Explorer.SmartContract.RustVerifierInterfaceBehaviour)[:api_key]

        if api_key do
          [{"x-api-key", api_key} | headers]
        else
          headers
        end
      end

      def http_get_request(url) do
        start_time = System.monotonic_time(:microsecond)
        endpoint = verification_endpoint_from_url(url)

        result =
          case HTTPoison.get(url) do
            {:ok, %Response{body: body, status_code: 200}} ->
              process_verifier_response(body)

            {:ok, %Response{body: body, status_code: _}} ->
              {:error, body}

            {:error, error} ->
              old_truncate = Application.get_env(:logger, :truncate)
              Logger.configure(truncate: :infinity)

              Logger.error(fn ->
                [
                  "Error while sending request to verification microservice url: #{url}: ",
                  inspect(error, limit: :infinity, printable_limit: :infinity)
                ]
              end)

              Logger.configure(truncate: old_truncate)
              {:error, @request_error_msg}
          end

        duration = (System.monotonic_time(:microsecond) - start_time) / 1_000_000
        record_verification_metrics(endpoint, duration, result)

        result
      end

      def get_versions_list do
        http_get_request(versions_list_url())
      end

      def vyper_get_versions_list do
        http_get_request(vyper_versions_list_url())
      end

      def process_verifier_response(body) when is_binary(body) do
        case Jason.decode(body) do
          {:ok, decoded} ->
            process_verifier_response(decoded)

          _ ->
            {:error, body}
        end
      end

      def process_verifier_response(%{"status" => "SUCCESS", "source" => source}) do
        {:ok, source}
      end

      def process_verifier_response(%{"status" => "FAILURE", "message" => error}) do
        {:error, error}
      end

      def process_verifier_response(%{"compilerVersions" => versions}), do: {:ok, versions}

      def process_verifier_response(other), do: {:error, other}

      def solidity_multiple_files_verification_url,
        do: "#{base_api_url()}" <> "/verifier/solidity/sources:verify-multi-part"

      def vyper_multiple_files_verification_url, do: "#{base_api_url()}" <> "/verifier/vyper/sources:verify-multi-part"

      def vyper_standard_json_verification_url,
        do: "#{base_api_url()}" <> "/verifier/vyper/sources:verify-standard-json"

      def solidity_standard_json_verification_url,
        do: "#{base_api_url()}" <> "/verifier/solidity/sources:verify-standard-json"

      def versions_list_url, do: "#{base_api_url()}" <> "/verifier/solidity/versions"

      def vyper_versions_list_url, do: "#{base_api_url()}" <> "/verifier/vyper/versions"

      def base_api_url, do: "#{base_url()}" <> "/api/v2"

      def base_url do
        RustService.base_url(Explorer.SmartContract.RustVerifierInterfaceBehaviour)
      end

      def enabled?, do: Application.get_env(:explorer, Explorer.SmartContract.RustVerifierInterfaceBehaviour)[:enabled]

      defp append_metadata(body, metadata) when is_map(body) do
        body
        |> Map.put("metadata", metadata)
      end
    end
  end
end
