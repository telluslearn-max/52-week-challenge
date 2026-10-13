FROM elixir:1.17

ENV MIX_ENV=prod LANG=C.UTF-8
WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock* ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile

COPY lib lib
COPY priv priv
RUN mix compile

# Migrate, then serve. Railway provides PORT and DATABASE_URL.
CMD ["sh", "-c", "mix ecto.migrate && mix phx.server"]
