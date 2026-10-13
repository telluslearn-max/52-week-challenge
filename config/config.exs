import Config

config :savings_challenge,
  ecto_repos: [SavingsChallenge.Repo],
  # Kenya is UTC+3 with no DST; used to decide what "today" means.
  utc_offset_hours: 3

config :savings_challenge, SavingsChallengeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: SavingsChallengeWeb.ErrorHTML], layout: false],
  pubsub_server: SavingsChallenge.PubSub,
  live_view: [signing_salt: "w52k-savings-lv"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :savings_challenge, :mailer, adapter: :log

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
