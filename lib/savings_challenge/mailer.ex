defmodule SavingsChallenge.Mailer do
  @moduledoc """
  Sends plain-text email. Adapter is chosen by `config :savings_challenge, :mailer`:

    * `[adapter: :resend, api_key: ..., from: ...]` - Resend's HTTPS API (production)
    * `[adapter: :log]`  - logs the message (development)
    * `[adapter: :test]` - keeps messages in memory for assertions
    * `[adapter: :none]` - refuses to send (nothing configured)
  """
  require Logger

  def deliver(to, subject, text) do
    config = Application.get_env(:savings_challenge, :mailer, adapter: :none)
    deliver(config[:adapter], config, to, subject, text)
  end

  defp deliver(:log, _config, to, subject, text) do
    Logger.info("[mail to #{to}] #{subject}\n#{text}")
    :ok
  end

  defp deliver(:test, _config, to, subject, text) do
    Agent.update(__MODULE__.Inbox, &[%{to: to, subject: subject, text: text} | &1])
    :ok
  end

  defp deliver(:resend, config, to, subject, text) do
    body = Jason.encode!(%{from: config[:from], to: [to], subject: subject, text: text})

    request =
      {~c"https://api.resend.com/emails", [{~c"authorization", String.to_charlist("Bearer " <> config[:api_key])}],
       ~c"application/json", body}

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(:post, request, [ssl: ssl, timeout: 15_000], []) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 ->
        :ok

      {:ok, {{_, status, _}, _, resp}} ->
        Logger.error("mail failed: HTTP #{status} #{inspect(resp)}")
        {:error, :send_failed}

      {:error, reason} ->
        Logger.error("mail failed: #{inspect(reason)}")
        {:error, :send_failed}
    end
  end

  defp deliver(_none, _config, _to, _subject, _text), do: {:error, :not_configured}
end

defmodule SavingsChallenge.Mailer.Inbox do
  @moduledoc "In-memory mailbox used by the :test adapter."
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)
  def all, do: Agent.get(__MODULE__, & &1)
  def clear, do: Agent.update(__MODULE__, fn _ -> [] end)
end
