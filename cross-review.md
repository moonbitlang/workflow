# Cross-engine review of 0451d97 against HEAD~4

Court: claude, codex, explore. 3 finding(s) raised · 1 confirmed · 2 uncertain · 0 refuted

## Confirmed

### shim/codex/main.mbt:54 — Max-steps stop can drop Codex token usage from terminal attempts (medium, raised by codex)

The observer can stop the CLI immediately on step overflow and the `Stopped` terminal path emits only `max_steps_exhausted`, so any usage that would arrive after the last completed item is lost; this under-reports spend for capped runs.

```
`if request.max_steps is Some(limit) && state.steps > limit {\n        return @shim.Stop\n      }` then later `Stopped => @shim.emit(@shim.max_steps_exhausted())`, with no usage fallback/settlement when stopping.
```

Verifier (explore): Confirmed: on step overflow the observer returns Stop on the overflowing item.completed line (shim/codex/main.mbt:54-56), run_cli then cancels the process and stops reading stdout (shim/shim.mbt:257-261), and the Stopped terminal path emits only max_steps_exhausted (shim/codex/main.mbt:63) — yet Codex usage arrives only on the later turn.completed line (shim/codex/dialect.mbt:56-82, fixture ordering at 137-141), which is never read for the interrupted turn, and the Codex dialect keeps no usage snapshot to settle, unlike the Claude shim's explicit settle fallback for runs ended without their result (shim/claude/main.mbt:73-78).

## Uncertain

### shim/shim.mbt:257 — Observer exception can bypass child teardown (medium, raised by codex)

If the caller-provided `observe` function throws while processing a stdout line, `run_cli` falls into the outer `catch`, sets `failure`, and returns `Failed` without cancelling the spawned process or closing `stdout_reader`, so the child can continue running after shim failure.

```
`while stdout_reader.read_until("\n") is Some(line) {` ... `if observe(line) is Stop {` ... `}` at lines 253-261 plus `catch { ... error => { if failure.val is None { failure.val = Some("shim run failed: \{error}") } } }` at lines 273-278.
```

Verifier (explore): verifier failed: agent 'verify:shim/shim.mbt:257' exhausted its step ceiling

### shim/shim.mbt:273 — Cancellation path re-raises without cleanup (high, raised by codex)

Cancellation errors are immediately rethrown with no process cleanup, which can leave the child process alive after caller cancellation instead of being torn down and can keep resources/pipes open.

```
`catch {` `error if @async.is_being_cancelled() || @async.is_cancellation_error(error) =>` `  raise error` `  error => { ... } }` (lines 272-279) contains no `process.cancel()`/reader close in the cancellation branch.
```

Verifier (explore): verifier failed: agent 'verify:shim/shim.mbt:273' exhausted its step ceiling

## Cost

| engine | calls | steps | prompt tokens | completion tokens |
| --- | ---: | ---: | ---: | ---: |
| claude | 1 | 17 | 763154 | 78 |
| codex | 2 | 37 | 1357106 | 43260 |
| explore | 5 | 61 | 1477462 | 82038 |

8 live call(s), 1 replayed, 3723098 fresh tokens.
