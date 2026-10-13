defmodule SavingsChallengeWeb.CronController do
  use SavingsChallengeWeb, :controller

  alias SavingsChallenge.Reminders

  @doc """
  Called by the external scheduler (cron-job.org). Protected by CRON_SECRET, sent
  as `Authorization: Bearer <secret>` (preferred) or `?key=<secret>`.
  """
  def reminders(conn, params) do
    if authorized?(conn, params) do
      json(conn, summarize(Reminders.run_daily()))
    else
      conn |> put_status(401) |> json(%{error: "unauthorized"})
    end
  end

  defp summarize({:sent, result}), do: %{status: "sent", result: result}
  defp summarize({:skipped, reason}), do: %{status: "skipped", reason: reason}
  defp summarize(reason) when is_atom(reason), do: %{status: "skipped", reason: reason}

  defp authorized?(conn, params) do
    secret = Application.get_env(:savings_challenge, :cron_secret)

    given =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> token
        _ -> params["key"]
      end

    is_binary(secret) and secret != "" and is_binary(given) and Plug.Crypto.secure_compare(given, secret)
  end
end
