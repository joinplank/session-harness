# MARKETPLACE.md — the `session-harness` marketplace lifecycle

This repo doubles as a **Claude Code plugin marketplace** (`session-harness`), defined at
[`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json). It lists one plugin:
`session-harness` (source `./session-harness`).

Two lifecycles: shipping an update, and receiving one.

---

## Maintainer: shipping an update

1. **Edit the bundle** — `session-harness/{commands,skills,scripts}/…`. Never the repo root's
   `scripts/` or `.claude/`: those are synced *from* the bundle and a build overwrites them.
2. **Bump `version` in `session-harness/.claude-plugin/plugin.json`.** This is the single source
   of version truth — the marketplace entry intentionally omits `version`, so there's no second
   place to forget. Claude resolves the installed version from `plugin.json` first, then a
   marketplace-entry `version` (unused here), then commit SHA.
   > ⚠️ **Footgun:** edit the bundle without bumping its `plugin.json` version and users who
   > already installed get **nothing** — no update prompt, no new behavior — even after
   > `/plugin marketplace update`. Bumping the version is the lever that ships the update.
3. **Add a `CHANGELOG.md` entry** in the bundle (Keep a Changelog format — see existing entries).
4. **Run `session-harness/build.sh`.** It validates both manifests, runs `claude plugin validate`
   and both test suites, re-syncs this repo's own harness from the bundle, proves the vendored
   layout still resolves its helper, and regenerates `dist/`. Any failure aborts with `dist/` and
   the repo-root harness untouched.
5. **Commit and push** to the default branch. The `dist/` artifacts are committed so a one-file
   install needs no build step.

### Adding a plugin

Add an entry to `marketplace.json`'s `plugins` array: `name` (must exactly match that bundle's
own `plugin.json` `name` — `build.sh` checks this) plus `source`, a relative `./<dir>` path from
the repo root (no `../`). Optionally add `description`. Do not set `version` here.

### Removing a plugin

Remove its entry. Existing installs are unaffected until users next update the marketplace;
consider a deprecation note in the bundle's `CHANGELOG.md` first.

### Renaming a plugin

If a plugin's `name` changes in its own `plugin.json`, add a `renames` map at the top level of
`marketplace.json` so existing installs migrate cleanly instead of erroring:

```json
{
  "renames": { "old-plugin-name": "new-plugin-name" }
}
```

---

## User: installing and updating

```
/plugin marketplace add joinplank/session-harness
/plugin install session-harness@session-harness
```

Use the GitHub `owner/repo` form — a raw-URL source breaks the marketplace's relative `source`
paths. Then, per repo you want to run the flow in, run `/session-harness:harness-setup` once.

To update:

```
/plugin marketplace update session-harness
/plugin install session-harness@session-harness
```

- `marketplace update` refreshes the marketplace manifest (new, removed or renamed entries, and
  the latest `plugin.json` version pointers) from the default branch.
- Background auto-update fires only when the **pinned version actually changes** — if a maintainer
  skipped step 2 above, nothing happens for installed users even after `update`.
- A repo that **vendored** the harness shadows the plugin's bare command names, so it will not
  pick up a plugin update at all. Re-vendor deliberately, or drop the vendored copy and let the
  plugin's `/session-harness:*` commands take over.
