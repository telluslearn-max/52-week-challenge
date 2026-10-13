import Config

config :savings_challenge, SavingsChallengeWeb.Endpoint, force_ssl: [rewrite_on: [:x_forwarded_proto]]

config :logger, level: :info
