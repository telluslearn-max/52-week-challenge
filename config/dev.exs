import Config

config :savings_challenge, SavingsChallenge.Repo,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: "savings_challenge_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :savings_challenge, SavingsChallengeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  debug_errors: true,
  secret_key_base: "dev-only-secret-key-base-dev-only-secret-key-base-dev-only-secret-key-base-1234"

config :logger, :console, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
