import Config

config :savings_challenge, SavingsChallenge.Repo,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: "savings_challenge_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :savings_challenge, SavingsChallengeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-only-secret-key-base-test-only-secret-key-base-test-only-secret-key-base-1234",
  server: false

config :logger, level: :warning
