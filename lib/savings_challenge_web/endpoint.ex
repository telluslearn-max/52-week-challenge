defmodule SavingsChallengeWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :savings_challenge

  @session_options [
    store: :cookie,
    key: "_savings_challenge_key",
    signing_salt: "w52k-savings-session",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Static, at: "/", from: :savings_challenge, gzip: false, only: SavingsChallengeWeb.static_paths()

  # Phoenix + LiveView client libraries are served straight from their deps,
  # so the app needs no Node/esbuild toolchain.
  plug Plug.Static, at: "/vendor/phoenix", from: {:phoenix, "priv/static"}, only: ~w(phoenix.min.js)
  plug Plug.Static, at: "/vendor/live_view", from: {:phoenix_live_view, "priv/static"}, only: ~w(phoenix_live_view.min.js)

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug SavingsChallengeWeb.Router
end
