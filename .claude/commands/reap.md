---
description: Clean up finished work — recycle merged interactive sessions into warm idle clones (and fast-forward local main to merged work).
allowed-tools: Bash
---

Run the session reaper and present its output:

```bash
scripts/session.sh reap
```

For every session whose **PR is merged** (confirmed — not just issue-closed) and whose tree is
clean, it **resets the numbered slot to a warm idle clone** in place — reset to `main`, drop
the task branch, but **keep `node_modules`/`.next`** — so the next `session.sh new` reclaims it
instead of paying for a cold `npm install`. Sessions still being worked (issue open, not yet
adopted, or with a dirty tree) are left untouched; lookups fail closed (a gh/network error
leaves the session). It finishes by fast-forwarding your local `main` to merged work (only when
that's unambiguously safe).

Report how many sessions were reaped, how many warm idle clones are now available, and what
(if anything) remains in flight.
