# Codex + Claude simplification review — 2026-09-22

This review covers the eight packages at `bd1bc1395c284c558f594e7147ff4a4c3b656517`.
The review workflow is a separate change in [PR #33](https://github.com/moonbitlang/workflow/pull/33);
this follow-up implements the selected findings below. The engines ran
separately. Claude disclosed reading the earlier Codex report for some packages,
so overlap is not independent blinded confirmation. Repeated findings were
combined by location and intended change, then checked against code and tests.

## Execution and limits

- Codex CLI 0.153.4 completed all eight package reviews through the locally built
  shim. The published shim was also exercised on `examples/scout`.
- Claude Code 2.1.278 completed all eight package reviews through the published
  shim with its default tool
  policy: file-reading tools available, Bash and editing tools disallowed.
- A separate run of the new workflow reviewed `examples/scout` with both engines
  concurrently and completed 2/2 calls, using explicit Codex reasoning and Claude
  effort settings. Per-engine model overrides and argv forwarding were also
  checked with deterministic contract fixtures.
- These were static reviews, not agent-run compiler checks. Claude reported
  denied reads of some external `~/.moon/lib/core` files. Replacement APIs used
  below were subsequently checked with `moon ide doc` and the actual compiler.
- Some reports suggested constructing the read-only `Json::Object` variant.
  The implementation uses the public `Json::object` factory instead. Suggested
  code was not copied blindly.

## Combined decisions

| Package | Adopted simplifications | Review source |
| --- | --- | --- |
| Core | Build `JournalEntry` JSON fields directly instead of constructing an object and immediately destructuring it; calculate default labels only when absent. | JSON: both; lazy labels: Codex |
| `shim` | Build usage fields directly; use the first `ArrayView::search("--")` match instead of a mutable scan. | Usage: both; argv search: Codex |
| `spawn` | Build request fields directly; parse trimmed views with an early return on invalid JSON; merge identical failure assignments; forward `cwd` and `extra_env` directly. | Request: both; parsing/failure branches: Codex; option forwarding: Claude |
| `hosted` | Keep the terminal match exhaustive and construct the common accounted failure once. | Codex; narrower than Claude's proposed cross-package API |
| `shim/codex` | Build report fields directly and parse trimmed string views without an intermediate `Option` or owned string. | Both (Claude suggested the early-return parser as well) |
| `shim/claude` | Build report fields directly, reuse the first-message check, append the common tool list once, and use the same early-return parsing style. | Both for report/tool-list/message checks; shared parsing style |
| `viz` | Precompute each answer's JSON-escaped dataflow probe once, preserving the 60-unit threshold, surrogate-safe 50-unit prefix, and edge order. | Both |
| `examples/scout` | Express the exact one-value positional constraint with `ValueRange::single()`. | Codex; Claude repeated it with an explicit API-verification caveat |

The JSON builders preserve field insertion order, optional-field omission,
numeric representation and wire shape. Event classifiers retain their existing
recorded dialect fixtures; no CLI format change is introduced. The child contract
and public package interfaces are unchanged.

## Deferred findings

- **Lifecycle cleanup and captured state:** Claude proposed simplifying `Ref`
  state and consolidating nested cleanup/error handlers in `shim` and `spawn`.
  Resource-close ordering, task-group failure and cancellation deserve a
  separate change; they are not needed for these local simplifications.
- **Cross-package outcome conversion:** Claude proposed a public
  `ContractResult::outcome` method shared by `spawn` and `hosted`. That adds API
  surface and would unify two currently distinct invariant-error messages.
  This change keeps both ownership and messages intact.
- **Hosted finish-event helper:** both engines noticed duplicate event shapes.
  The cancellation path must continue using live counters inside cancellation
  protection. Keeping the two short constructions avoids mixing that lifecycle
  work into this refactor.
- **Broader root/viz reorganization:** journal constructor/decoder helpers,
  extracting rendering sections, and sharing small presentation helpers offer
  readability tradeoffs but are not required for the selected changes.
- **Public API removal:** compatibility aliases and `exports.mbt` entries remain.
  A lack of internal callers is not sufficient evidence to remove them.
- **CLI defaults and tiny helpers:** retain fallback behavior and executable-local
  argument helpers where removing them would add dependencies or require
  additional assumptions about parser behavior.

## Validation of the implemented changes

- `just check`: native and wasm type checks with warnings denied, plus formatting.
- `just test`: 112 tests pass on each target (106 previously).
- New boundary coverage includes sliced argv views and the first separator;
  exact usage JSON and absent versus zero price; malformed/CRLF/Unicode CLI
  lines; partial Claude usage snapshots; hosted failure identity, tokens, price
  and sidecar status; dataflow thresholds, JSON escaping and surrogate pairs.
- Rendered the same five-entry boundary-case journal with the old and new `viz`:
  both produce five edges and the complete HTML files compare byte-for-byte equal.
- `just tidy` leaves every `pkg.generated.mbti` unchanged.
