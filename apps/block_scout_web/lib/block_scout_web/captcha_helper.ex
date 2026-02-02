defmodule BlockScoutWeb.CaptchaHelper do
  @moduledoc """
  A helper for CAPTCHA
  """

  @callback recaptcha_passed?(String.t() | nil) :: bool
  @spec recaptcha_passed?(String.t() | nil) :: bool
  def recaptcha_passed?(nil), do: false

  def recaptcha_passed?(recaptcha_response) do
    start_time = System.monotonic_time(:microsecond)

    re_captcha_v2_secret_key = Application.get_env(:block_scout_web, :recaptcha)[:v2_secret_key]
    re_captcha_v3_secret_key = Application.get_env(:block_scout_web, :recaptcha)[:v3_secret_key]
    re_captcha_secret_key = re_captcha_v2_secret_key || re_captcha_v3_secret_key
    body = "secret=#{re_captcha_secret_key}&response=#{recaptcha_response}"

    headers = [{"Content-type", "application/x-www-form-urlencoded"}]

    result =
      case HTTPoison.post("https://www.google.com/recaptcha/api/siteverify", body, headers, []) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          case Jason.decode!(body) do
            %{"success" => true} = resp -> is_success?(resp)
            _ -> false
          end

        _ ->
          false
      end

    duration = (System.monotonic_time(:microsecond) - start_time) / 1_000_000
    record_recaptcha_metrics(duration, result)
    result
  end

  defp is_success?(%{"score" => score}) do
    check_recaptcha_v3_score(score)
  end

  defp is_success?(_resp), do: true

  defp check_recaptcha_v3_score(score) do
    if score >= 0.5 do
      true
    else
      false
    end
  end

  # =============================================================================
  # Metrics Helper Functions
  # =============================================================================

  defp record_recaptcha_metrics(duration_seconds, result) do
    alias Explorer.Prometheus.Instrumenter

    if Code.ensure_loaded?(Instrumenter) do
      try do
        status = if result, do: :success, else: :error
        Instrumenter.external_api_request(:recaptcha, duration_seconds, status)
      rescue
        _ -> :ok
      end
    end
  end
end
