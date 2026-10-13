# Future features

Ideas discussed but not built yet. Nothing here is committed to.

## Offline mode
Today the installed app shows an "You're offline" screen and never caches
savings data (see `priv/static/sw.js`). Real offline use would mean:

- Keep a local copy of goals and let the user record deposits offline.
- Sync queued deposits when back online. Each deposit already carries a unique
  idempotency key, so a retried sync cannot count twice.
- Lock the offline copy on the phone as well, so the PIN still protects it.
- Decide how to resolve a deposit edited on two devices.

Worth doing only if saving often happens with no signal.

## Flexible rebalancing for fixed weekly plans
Daily, deadline and bill goals re-spread what is left over the remaining
periods (`Plan.adaptive?/1`). The fixed-amount weekly plan and the envelope
challenge keep their fixed schedules. Option: let a goal opt in to rebalancing.

## Superfans-style challenge
A challenge type like the one in the inspiration screenshots.

## Flexible challenge lengths
Let the user pick a custom number of periods for the classic challenge types.

## Carry surplus across bill cycles
When a repeating bill is paid with money left over, carry the surplus into the
next cycle instead of starting it at zero.

## Housekeeping
- Rotate the secrets that were shared during setup (Neon password, setup code,
  `CRON_SECRET`).
