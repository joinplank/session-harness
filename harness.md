# Harness

Interactive dev harness. **One task = one isolated clone + one attended Claude session.** Claude authors; **Codex is the adversary** (complementary tool — whoever authored never reviews); the **human merges**. Pre-production → clean breaks, no migrations/back-compat.

## Flow `/isession → /iharden → /iship`

| Phase | Command | Action | Exit |
|---|---|---|---|
| 1 · bootstrap | `/isession <one-liner>` | provision isolated clone `~/work/<repo>-session-NN` (branch `session/<slug>`), open cmux+Claude, discuss→plan | plan drafted |
| 2 · harden | `/iharden` | file plan → issue (`interactive:draft` = enforced gate), adopt → branch `task/<N>-<slug>`; **plan-critique loop**: author revises ⇄ Codex critiques | `APPROVED`/human-ok → emits `/goal` line |
| 3 · ship | `/iship` | `/goal` loop to bar: **simplify** diff → draft PR → **review loop** (concept pass once, after rd 1) → AC checklist → flip non-draft | READY PR → human merges · else **ESCALATED** |

## Gates — green-light `npm install && npm run build` re-run every round

| Gate | Script | Reviewer (env, default) | Loop | Cap | Verdict | Gates merge |
|---|---|---|---|---|---|---|
| plan critique | `plan-critique.sh` | Codex (`CRITIC`) | ✓ | quick2 / normal3 / **deep6** | `APPROVED`\|`CHANGES_REQUESTED` | ✓ severity |
| simplify | author self-edit | Claude | ✗ | — | — | ✗ clarity edit (pre-review) |
| code review | `run-review.sh` | Codex (`REVIEWER`) | ✓ | `REVIEW_MAX_ROUNDS` **3** | `APPROVED`\|`CHANGES_REQUESTED` | ✓ severity |
| concept pass | `concept-check.sh` | Claude (`CHECKER`) | ✗ once, after rd 1 | — | `MINIMAL`\|`SIMPLIFY` | ✗ advisory |

**Severity convergence** (not zero-findings): **BLOCKING** = correctness · security · data-loss · broken contract/API · regression · unmet-AC → must fix (simplest change that resolves it). **NIT** = style · naming · subjective · optional-refactor · doc → record, never loops. Code review is **diff-adversarial** (sees the diff, not the spec) → AC completeness is the human's, gated by the step-4 AC checklist, not the reviewer.

## Codex model + reasoning effort per call

| Call | Model | Effort | Round signal |
|---|---|---|---|
| review · round 1 | sol | **ultra** | `--round 1` |
| review · rounds 2+ | sol | xhigh | `--round N` |
| plan critique · round 1 | sol | **ultra** | empty `--thread` |
| plan critique · rounds 2+ | sol | xhigh | populated `--thread` |
| review classifier | sol | inherited | mechanical triage — never scales |
| concept-check (only if `CHECKER=codex`) | sol | inherited | advisory |

- ladder `low<medium<high<xhigh<max<ultra`; **`max`+`ultra` only on sol/terra**. `ultra` = max reasoning + automatic task delegation.
- pins: **`CODEX_MODEL`** (default `gpt-5.6-sol`), **`CODEX_EFFORT`** (forces one tier for all rounds; unset ⇒ round policy above). Unset effort on non-scaling calls ⇒ global `~/.codex` (currently `xhigh`).
- effort scales only on the reasoning-heavy adversary calls (review + plan critic); classifier + concept-check stay cheap. The sol pin is what unlocks `ultra`.

## Escalate → don't merge, issue stays OPEN, draft PR + `interactive:escalated`

un-greenable build · unresolvable real finding · unclean merge · genuine ambiguity · cap hit still `CHANGES_REQUESTED`.

## Invariants

- one issue → one branch `task/<N>-<slug>` → one PR → **human merges**
- complementary pairing is fixed: Claude implements → Codex reviews; reverse via `--reviewer claude` / `CRITIC=claude` / `CHECKER=codex`
- **two concept reviews**: plan-vocab ledger (`/iharden`, design altitude, pre-code) vs realized-code audit (`/iship`, impl altitude, post-rd-1)
- stay in your clone; never `git push --force` (only `--force-with-lease`); don't hand-edit `package-lock.json`
- state = per-clone `.session.json` (gitignored); no registry — `session.sh list` scans `<repo>-session-*`; `SESSION_MAX` 6; `reap`/`release` recycle merged slots → warm idle clones
- durable adversarial trail: each critique round → issue comment; each review round + the concept ledger → PR comment
