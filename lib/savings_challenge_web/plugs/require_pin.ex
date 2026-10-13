defmodule SavingsChallengeWeb.Plugs.RequirePin do
  @moduledoc """
  Keeps the app behind the PIN once one is set. Used as a plug (first request)
  and as a LiveView `on_mount` hook (so a websocket cannot bypass it).
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias SavingsChallenge.Lock

  # An unlocked session is valid for 12 hours at most; the browser also locks
  # itself after a few idle minutes (see assets/app.js).
  @max_age 12 * 3600

  def init(opts), do: opts

  def call(conn, _opts) do
    if Lock.pin_set?() and not unlocked?(get_session(conn)) do
      conn |> redirect(to: "/unlock") |> halt()
    else
      conn
    end
  end

  def on_mount(:default, _params, session, socket) do
    if Lock.pin_set?() and not unlocked?(session) do
      {:halt, Phoenix.LiveView.redirect(socket, to: "/unlock")}
    else
      {:cont, socket}
    end
  end

  def unlocked?(%{"unlocked_at" => at}) when is_integer(at), do: System.system_time(:second) - at < @max_age
  def unlocked?(_session), do: false
end
