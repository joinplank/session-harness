# Harness

Interactive dev harness. **One task = one isolated clone + one attended Claude session.** Claude authors; **Codex is the adversary** (complementary tool — whoever authored never reviews); the **human merges**. Pre-production → clean breaks, no migrations/back-compat.

Shipped as the `session-harness` **plugin** (`session-harness/`, the canonical source); this repo's `scripts/` + `.claude/` are its synced copy — the dogfood, and the only exercise the vendored layout gets. Both layouts are resolved by the same text: commands read `${CLAUDE_PLUGIN_ROOT}` and fall back to the repo; `run-review.sh` finds `model-call.sh` in the `scripts/` beside its install root.

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
| third opinion | `run-review.sh --reviewer deepseek` | DeepSeek via `opencode` | ✗ on request | — | `APPROVED`\|`CHANGES_REQUESTED` | ✗ **advisory** |
| directed probe | `run-review.sh --ask <q>` | selected reviewer | ✗ on request | — | *(none by design)* | ✗ **advisory** |

**Severity convergence** (not zero-findings): **BLOCKING** = correctness · security · data-loss · broken contract/API · regression · unmet-AC → must fix (simplest change that resolves it). **NIT** = style · naming · subjective · optional-refactor · doc → record, never loops. Code review is **diff-adversarial** (sees the diff, not the spec) → AC completeness is the human's, gated by the step-4 AC checklist, not the reviewer.

**Advisory ≠ gate, and it follows from being optional**: a pass that is sometimes skipped is one nothing that merges can depend on. So a DeepSeek pass and a probe take **no round**, their verdict does not block, and their failures say *record it and carry on* where a gating reviewer's say *escalate, do not merge* — `run-review.sh` decides that once, up front, and every message downstream reads from it. Findings are dispositioned like the concept pass's (applied, or declined with a one-line rationale) and posted to the PR.

## Every model call is supervised — `model-call.sh`

Sourced by `plan-critique.sh`, `concept-check.sh`, `run-review.sh`. Two failure modes both end as *a round that silently did not happen*: it hangs forever, or it dies mid-stream having produced nothing.

| Property | Rule |
|---|---|
| bound | `MODEL_CALL_TIMEOUT_S` **1800 s** — an order of magnitude above the longest real call, so only a *stopped* one reaches it. A fired bound outranks a zero exit status. |
| isolation | each attempt writes to private scratch; **only a successful attempt is published** to `--out`, so a dead attempt's bytes can never splice into a retry's |
| retry | **opt-in**, and the rule is the sandbox flag, not the prompt: `codex exec … -s read-only` earns one (classifier, Codex probe); `codex exec review --base`, `claude -p --dangerously-skip-permissions`, `opencode run --pure` are bounded and run **once** |
| cancellation | each attempt leads its own process group — an interrupted supervisor kills the call and its descendants, and removes the partial output |

`session-harness/tests/model-call.test.sh` (30 assertions) + `tests/run-review.test.sh` prove these against stand-in CLIs on every `build.sh`. No model call, seconds to run.

## Codex model + reasoning effort per call

| Call | Model | Effort | Round signal |
|---|---|---|---|
| review · round 1 | sol | **ultra** | `--round 1` |
| review · rounds 2+ | sol | xhigh | `--round N` |
| plan critique · round 1 | sol | **ultra** | empty `--thread` |
| plan critique · rounds 2+ | sol | xhigh | populated `--thread` |
| review classifier | sol | inherited | mechanical triage — never scales |
| concept-check (only if `CHECKER=codex`) | sol | inherited | advisory |
| DeepSeek pass / probe | `DEEPSEEK_MODEL` (`deepseek/deepseek-v4-pro`) | n/a | advisory |

- ladder `low<medium<high<xhigh<max<ultra`; **`max`+`ultra` only on sol/terra**. `ultra` = max reasoning + automatic task delegation.
- pins: **`CODEX_MODEL`** (default `gpt-5.6-sol`), **`CODEX_EFFORT`** (forces one tier for all rounds; unset ⇒ round policy above), **`DEEPSEEK_MODEL`**. Pinned rather than inherited so a gate never drifts with a machine's global default.
- effort scales only on the reasoning-heavy adversary calls (review + plan critic); classifier + concept-check stay cheap. The sol pin is what unlocks `ultra`.
- **`DEEPSEEK_MAX_DIFF` 200 000 B** — an oversized branch is **refused, never truncated**: a clipped diff reads as a complete review over code the model never saw, and nobody re-checks an advisory verdict.

## Escalate → don't merge, issue stays OPEN, draft PR + `interactive:escalated`

un-greenable build · unresolvable real finding · unclean merge · genuine ambiguity · cap hit still `CHANGES_REQUESTED`. An **advisory** pass failing is never one of these.

## Invariants

- one issue → one branch `task/<N>-<slug>` → one PR → **human merges**
- complementary pairing is fixed: Claude implements → Codex reviews; reverse via `--reviewer claude` / `CRITIC=claude` / `CHECKER=codex`
- **two concept reviews**: plan-vocab ledger (`/iharden`, design altitude, pre-code) vs realized-code audit (`/iship`, impl altitude, post-rd-1)
- every round gets its **own `--out`** — until its comment is posted those two files are the round's only copy, so an occupied path is refused, never overwritten
- stay in your clone; never `git push --force` (only `--force-with-lease`); don't hand-edit `package-lock.json`
- don't hand-edit `scripts/` or `.claude/` — synced from `session-harness/` by its `build.sh`
- state = per-clone `.session.json` (gitignored); no registry — `session.sh list` scans `<repo>-session-*`; `SESSION_MAX` 6; `reap`/`release` recycle merged slots → warm idle clones
- durable adversarial trail: each critique round → issue comment; each review round, the concept ledger, and any advisory pass → PR comment
