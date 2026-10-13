defmodule SavingsChallengeWeb.SessionController do
  use SavingsChallengeWeb, :controller

  alias SavingsChallenge.Lock

  # LiveView verified the PIN and sent the browser here with a 60-second token.
  def complete(conn, %{"t" => token}) do
    case Phoenix.Token.verify(SavingsChallengeWeb.Endpoint, "unlock", token, max_age: 60) do
      {:ok, _} ->
        conn
        |> configure_session(renew: true)
        |> put_session(:unlocked_at, System.system_time(:second))
        |> redirect(to: "/")

      _ ->
        redirect(conn, to: "/unlock")
    end
  end

  def complete(conn, _params), do: redirect(conn, to: "/unlock")

  def lock(conn, _params) do
    conn = configure_session(conn, drop: true)
    redirect(conn, to: if(Lock.pin_set?(), do: "/unlock", else: "/"))
  end
end
