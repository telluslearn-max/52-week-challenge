import Config

if System.get_env("PHX_SERVER") do
  config :savings_challenge, SavingsChallengeWeb.Endpoint, server: true
end

# One-time code that must be typed to create the PIN (stops a stranger claiming
# a fresh install). Leave unset locally.
if config_env() != :test do
  config :savings_challenge, :setup_code, System.get_env("SETUP_CODE")
end

# Web Push (VAPID) and the scheduler secret; unset locally means "feature off".
if config_env() != :test do
  if System.get_env("VAPID_PUBLIC_KEY") && System.get_env("VAPID_PRIVATE_KEY") do
    config :savings_challenge, :vapid, %{
      public: System.get_env("VAPID_PUBLIC_KEY"),
      private: System.get_env("VAPID_PRIVATE_KEY"),
      subject: System.get_env("VAPID_SUBJECT", "mailto:admin@example.com")
    }
  end

  config :savings_challenge, :cron_secret, System.get_env("CRON_SECRET")
end

if config_env() == :prod do
  if api_key = System.get_env("RESEND_API_KEY") do
    config :savings_challenge, :mailer,
      adapter: :resend,
      api_key: api_key,
      from: System.get_env("MAIL_FROM", "Savings <onboarding@resend.dev>")
  end

  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing, e.g. ecto://USER:PASS@HOST/DATABASE"

  # Neon/Render style URLs carry libpq params (sslmode, channel_binding) that
  # Ecto does not understand: strip them and configure TLS explicitly.
  db_uri = URI.parse(database_url)
  clean_url = URI.to_string(%{db_uri | query: nil})

  ssl_opts =
    if System.get_env("DATABASE_SSL") in ~w(true 1) do
      [
        ssl: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: String.to_charlist(db_uri.host),
          customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
        ]
      ]
    else
      []
    end

  config :savings_challenge,
         SavingsChallenge.Repo,
         [
           url: clean_url,
           socket_options: if(System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []),
           pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")
         ] ++ ssl_opts

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing. Generate one with: mix phx.gen.secret"

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :savings_challenge, SavingsChallengeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    # Single-user prototype behind Railway's proxy; tighten if you add auth.
    check_origin: false,
    secret_key_base: secret_key_base
end
