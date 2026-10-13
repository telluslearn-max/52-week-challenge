# 52-Week Savings Challenge

A mobile-first savings tracker built with Phoenix LiveView and PostgreSQL. Configure a 52-week
challenge, see all 52 weeks in a grid, record deposits, and watch your progress ring and
cumulative chart update live. Default currency is KSh (KES).

## Run it

Requires Elixir 1.14+ (Erlang/OTP 25+) and PostgreSQL.

```sh
mix setup          # fetch deps, create + migrate the database
mix phx.server     # http://localhost:4000
mix test
```

Dev DB defaults to `postgres`/`postgres` on localhost; override with `DB_USER`, `DB_PASSWORD`, `DB_HOST`.
For production set `DATABASE_URL`, `SECRET_KEY_BASE` (`mix phx.gen.secret`) and `PHX_HOST`, then run
`mix ecto.migrate` before starting with `PHX_SERVER=true`.

There is no Node toolchain: the Phoenix/LiveView JS is served from the deps and the CSS is a single plain file.

## How it works

- `SavingsChallenge.Plan` – pure maths: weekly targets (increasing or fixed), week statuses
  (completed / current / missed / upcoming), dashboard totals and chart series.
- `SavingsChallenge.Savings` – context. Every write runs in a transaction that locks the challenge row.
  Totals are **never stored**; they are summed from the contributions on every change, so edits and
  deletes cannot drift. A per-form idempotency token with a unique index stops a double tap
  from recording a deposit twice.
- `SavingsChallengeWeb.DashboardLive` – the single screen.
- Server-side validation on every field (amount > 0, week 1–52, no future dates, etc.), plus DB check constraints.

## Scope notes

- Single-user prototype: **no authentication** (the brief makes it optional). To host for several users, add
  auth and a `user_id` on `challenges`; `Savings` already scopes everything by challenge.
- Amounts are whole shillings. "Today" is computed at UTC+3 (`:utc_offset_hours`).
- Current week = weeks elapsed since the start date, capped to 1..52.
