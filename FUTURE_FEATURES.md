# Future features

Ideas discussed but not built yet. Nothing here is committed to.

Done since this list was started: rebalancing for fixed-amount weekly plans,
and carrying surplus into the next bill cycle.

## Offline mode
Today the installed app shows an "You're offline" screen and never caches
savings data (see `priv/static/sw.js`). Real offline use would mean:

- Keep a local copy of goals and let the user record deposits offline.
- Sync queued deposits when back online. Each deposit already carries a unique
  idempotency key, so a retried sync cannot count twice.
- Lock the offline copy on the phone as well, so the PIN still protects it.
- Decide how to resolve a deposit edited on two devices.

Worth doing only if saving often happens with no signal.

## Superfans-style challenge
A challenge type like the one in the inspiration screenshots.

## Flexible challenge lengths
Let the user pick a custom number of periods for the classic challenge types.

## Housekeeping
- Rotate the secrets that were shared during setup (Neon password, setup code,
  `CRON_SECRET`).
