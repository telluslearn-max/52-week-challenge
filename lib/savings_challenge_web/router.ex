defmodule SavingsChallengeWeb.Router do
  use SavingsChallengeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SavingsChallengeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_lock_flag
  end

  # Tells the layout whether to run the idle auto-lock script.
  defp put_lock_flag(conn, _opts), do: assign(conn, :autolock, SavingsChallenge.Lock.pin_set?())

  # Machine endpoint for the external scheduler: no session, no CSRF, own secret.
  scope "/cron", SavingsChallengeWeb do
    get "/reminders", CronController, :reminders
    post "/reminders", CronController, :reminders
  end

  # Lock screens: never behind the PIN.
  scope "/", SavingsChallengeWeb do
    pipe_through :browser

    live "/unlock", LockLive, :enter
    live "/unlock/setup", LockLive, :setup
    live "/unlock/change", LockLive, :change
    live "/unlock/reset/:token", LockLive, :reset
    get "/unlock/complete", SessionController, :complete
    get "/lock", SessionController, :lock
  end

  # The app itself: behind the PIN once one is set.
  scope "/", SavingsChallengeWeb do
    pipe_through [:browser, SavingsChallengeWeb.Plugs.RequirePin]

    live_session :app, on_mount: {SavingsChallengeWeb.Plugs.RequirePin, :default} do
      live "/", HomeLive
      live "/reminders", NotifyLive
      live "/history", HistoryLive
      live "/goals/new", DashboardLive, :new
      live "/goals/:id", DashboardLive, :show
    end
  end
end
