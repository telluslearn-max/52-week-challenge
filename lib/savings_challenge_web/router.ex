defmodule SavingsChallengeWeb.Router do
  use SavingsChallengeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SavingsChallengeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # Single-user local prototype: no authentication (optional per the brief).
  # Add a pipeline + live_session here if this is ever hosted for many users.
  scope "/", SavingsChallengeWeb do
    pipe_through :browser

    live "/", DashboardLive
  end
end
