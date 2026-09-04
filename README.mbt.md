# moonbitlang/workflow

Engine-agnostic multi-agent workflow orchestration with journaled
replay/resume — a MoonBit take on the workflow-as-code model: a workflow
is an ordinary async program, the "graph" unfolds as it runs, and
durability comes from replaying a journal of typed outcomes rather than
from a static DAG.

The core package never spawns anything. Its one seam is `Runner`: a
single async function from `AgentCall` to `AgentOutcome`. Engines plug
in from the outside — through the `spawn` sub-package's child-contract
implementation for out-of-process engines, or any in-process function;
tests plug in fakes, which is why everything below runs hermetically.

## The failure model

Everything else follows from three decisions:

- **Failure is data, in a typed channel.** An agent that produced no
  usable report raises `WorkflowError::AgentFailed` with a typed
  `AgentFailure` cause; `try_agent` folds it into a `Result` for fan-out
  sites. A failure is never a silent `null`: it either raises
  `AgentFailed` or lands in `try_agent`'s `Result`.
- **Cost is never lost.** `AgentOutcome` carries the attempt's spend on
  BOTH arms — a timed-out child's tokens land in `tokens_spent()` just
  like a success's. `attempt=None` means no launch was ever tried.
  Engines that price their work report it too: `cost_usd()` sums their
  figures, and stays a floor when an engine in the mix prices nothing.
- **Cancellation is not failure.** Engine bugs and cancellation `raise`
  through and cancel the task group; the launch allowance only counts
  agents that actually launched — a call cancelled while queued costs
  nothing.

## A workflow, end to end

One phase fans three verifiers out over a finding, a quorum policy
requires at least 2 of the 3 CALLS to succeed (agreement between the
returned verdicts is then the script's own judgment, as the filter below
shows), and every launch is capped by the shared semaphore:

```mbt check
///|
async fn verdict_runner(call : @workflow.AgentCall) -> @workflow.AgentOutcome {
  @async.pause()
  let verdict : Json = if call.input is { "query": String(q), .. } &&
    q.contains("lens=repro") {
    { "confirmed": false }
  } else {
    { "confirmed": true }
  }
  Finished(value=verdict, attempt={
    attempt_id: "sr-\{call.label}",
    steps_used: 3,
    prompt_tokens: 70,
    completion_tokens: 30,
    cost_usd: None,
  })
}

///|
async test "fan out three lenses, gate on a 2-of-3 quorum" {
  let wf = @workflow.Workflow(
    runner=@workflow.Runner(verdict_runner),
    max_concurrent=4,
    max_calls=16,
  )
  wf.phase("Verify")
  let results = @workflow.fan_out(["correctness", "security", "repro"], lens => {
    wf.try_agent(
      kind="judge",
      "Judge the finding through lens=\{lens}: real?",
      label="verify:\{lens}",
    )
  })
  let confirmed = @workflow.quorum(results, need=2)
    .filter(v => v is { "confirmed": True, .. })
    .length()
  assert_eq(confirmed, 2)
  assert_eq(wf.calls_made(), 3)
  assert_eq(wf.tokens_spent(), 300)
}
```

`fan_out` gives every item its own `Result` slot — one lost verifier
never poisons its siblings, and the tokens they spent stay spent. When
later work is worthless without ALL of a stage, use `parallel_all`
instead: the first failure cancels every sibling still in flight. The
policies are one identifier each: `all_ok`, `collect_ok(min_ok?)`,
`quorum(need~)`. Both fan-outs are one task group: a raise inside one
cancels the rest and unwinds the whole stage, so nothing outlives it.

A model that answered off-schema or ran out of steps is often worth
asking again. `retry` wraps a RAISING step in the runtime's own retry
loop — `max_retry` extra attempts, spaced by `backoff` — and stops at
anything re-running cannot fix: a human's `Skipped` refusal, a spent
launch allowance, an engine bug, cancellation. Each attempt is a real
launch (its own slot, allowance, and tokens), and the journal records
each one, so a resumed run replays the attempt that finally answered:

```mbt check
///|
async test "retry until the engine actually answers" {
  let flaky : Ref[Int] = { val: 0, }
  let wf = @workflow.Workflow(
    runner=@workflow.Runner(call => {
      @async.pause()
      flaky.val += 1
      if flaky.val < 3 {
        DidNotFinish(failure=NoReport, attempt=None)
      } else {
        Finished(value={ "attempt": flaky.val }, attempt={
          attempt_id: "sr-\{call.label}",
          steps_used: 1,
          prompt_tokens: 40,
          completion_tokens: 10,
          cost_usd: None,
        })
      }
    }),
  )
  let report = @workflow.retry(
    () => wf.agent("Name the worst bug in spawn/", kind="judge"),
    max_retry=2,
  )
  assert_eq(report, { "attempt": 3 })
  assert_eq(wf.calls_made(), 3)
}
```

When the script wants a TYPE rather than JSON, decode at the boundary:
`agent_as` runs the same call and turns a report that does not satisfy
the type into a typed `AgentFailed(Failed("report rejected: …"))` carrying
the decoder's path. A `schema` rides the request envelope so an engine
that can constrain its model to the shape does (the Claude and Codex
shims do); decoding still runs, because the engine is not trusted to
validate, and the schema is part of the call's replay identity:

```mbt check
///|
struct Confirmation {
  confirmed : Bool
} derive(FromJson)

///|
async test "decode the report at the boundary" {
  let wf = @workflow.Workflow(runner=@workflow.Runner(verdict_runner))
  let verdict : Confirmation = wf.agent_as(
    "Judge the finding through lens=security: real?",
    kind="judge",
    schema={
      "type": "object",
      "properties": { "confirmed": { "type": "boolean" } },
      "required": ["confirmed"],
    },
  )
  assert_true(verdict.confirmed)
}
```

Multi-stage pipelines are just function composition inside the fan-out —
stages need no barrier between them, so composing them per-item IS the
pipeline:

```mbt check
///|
async test "find then verify, with no barrier between the stages" {
  let wf = @workflow.Workflow(runner=@workflow.Runner(verdict_runner))
  let verified = @workflow.fan_out(["pkg/a", "pkg/b"], target => {
    let finding = wf.try_agent("Find the worst bug in \{target}", kind="judge")
    match finding {
      // Each finding proceeds to verification the moment ITS finder
      // returns — b's finder may still be running while a verifies.
      Ok(_) =>
        wf.try_agent(
          "Adversarially verify the finding in \{target}",
          kind="judge",
        )
      Err(error) => Err(error)
    }
  })
  assert_eq(@workflow.all_ok(verified).length(), 2)
}
```

## Replay: crash, resume, and pay only for new work

Every live outcome is appended to the `Journal` — the call's WORK
identity (kind, input, max_steps, scope, schema — never the display label) plus
the lossless outcome, plus attribution for readers: the phase the call
was issued under and the wall-clock window it ran in, as milliseconds
since the epoch. Attribution never takes part in replay matching.
Re-running the same program against the same journal
replays successes for free, keeps a human's `Skipped` refusal standing,
and re-attempts other failures — getting past those is what resume is
for:

```mbt check
///|
async test "the second generation replays instead of re-paying" {
  let journal = @workflow.Journal::in_memory()
  let wf1 = @workflow.Workflow(
    runner=@workflow.Runner(verdict_runner),
    journal~,
  )
  let first = wf1.agent(
    "Judge the finding through lens=security: real?",
    kind="judge",
  )
  assert_eq(wf1.tokens_spent(), 100)

  // Same program, next generation: served from the journal — no launch,
  // no slot, no fresh spend.
  let wf2 = @workflow.Workflow(
    runner=@workflow.Runner(verdict_runner),
    journal=@workflow.Journal::in_memory(prior=journal.recorded()),
  )
  assert_eq(
    wf2.agent("Judge the finding through lens=security: real?", kind="judge"),
    first,
  )
  assert_eq(wf2.calls_made(), 0)
  assert_eq(wf2.calls_replayed(), 1)
  assert_eq(wf2.tokens_spent(), 0)
}
```

File-backed journals (`@workflow.Journal::load(path)`) are append-only JSONL,
accumulated across generations. A torn final line — the signature of
crashing mid-append — is dropped AND repaired on disk; corruption
anywhere else raises `JournalCorrupted`; the repair truncates to the last
healthy line and never re-encodes what it read. Identical concurrent
calls are intentional samples (three identical verifiers) and consume
entries as a multiset.

A v1 line that carries no entry is metadata: replay skips it and repair
preserves it, so a tool can annotate a journal, and a declared plan has a
place to live when one arrives. Labels follow the convention
`stage:instance` (`verify:claude:3`, `survey:journal`): readers group the
instances of one stage by the prefix before the first colon.

## Observability

`@workflow.Workflow(on_event=...)` narrates the run: `PhaseStarted`, `Log`, and an
`AgentStarted`/`AgentFinished` bracket that balances on EVERY path —
success, typed failure, cancellation (`Interrupted`), and infrastructure
error (`Errored`) — plus `AgentReplayed` for journal hits. Purely
observational: no control flow rides on events.

## Plugging in an engine

Any process that speaks the CHILD CONTRACT is already an engine: one
JSON line on stdin — the VERSIONED request envelope
`{"workflow_contract": 1, id, kind, max_steps?, schema?, input}`, with the pipe
held open (EOF is graceful cancel) — JSONL events on stdout
(`usage`/`agent_step` are accounted exactly), and one final
`{"subrun_report": ...}` line. The `spawn` sub-package is the contract's
one implementation:

```moonbit nocheck
///|
let runner = @spawn.contract_runner(launch=_ => {
  command: "my-engine",
  args: [],
  cwd: None,
  extra_env: None,
  deadline_ms: None,
})
```

For an engine whose reports are pure values, that is the whole adapter —
a shim around a Rust CLI needs only to translate framing, and gets
journal replay, budgets, and cancellation for free. An engine whose
reports name stateful resources should also pass `validate_replay`.

The wire contract in full — framing, cost accounting, terminal precedence,
and what the reference engine reads from the envelope versus argv — is
[docs/child-contract.md](docs/child-contract.md).

## Claude Code and Codex as engines

Two PROCESS SHIMS ship with this module: executables that speak the child
contract on their own stdin/stdout and drive `claude -p --output-format
stream-json` or `codex exec --json` underneath, translating framing both
ways. They are PUBLISHED, so a `LaunchSpec` points at a coordinate rather
than a path — no build step and nothing to hard-code, and nothing in the
library knows they exist:

```moonbit nocheck
///|
let runner = @spawn.contract_runner(launch=call => {
  command: "moonx",
  // read-only by default; `worker` calls (or --writable) may edit
  args: [
    "moonbitlang/workflow/shim/claude", "--model", "claude-sonnet-5", "--", "--max-budget-usd",
    "2",
  ],
  cwd: None,
  extra_env: None,
  deadline_ms: None,
})
```

`moonx` runs the WASM build, which both shims fully support — spawning
the CLI, holding the parent's stdin-EOF cancel channel open, and framing
stdout identically to the native build. It prints nothing of its own, so
the child's JSONL reaches the runner unpolluted, and a warm start costs
about 0.15s against an agent deadline measured in minutes. Pin the
version (`…/shim/claude@0.5.0`) when a run must be reproducible.

Building locally is for developing the shims themselves, where the
published version is not what you want to run:

```sh
just shims   # _build/native/debug/build/shim/{claude,codex}/*.exe
```

Both shims take the same options — `--command <exe>`, `--model <name>`,
`--cwd <dir>`, `--writable`, `--schema <file>`, and `-- <args…>` passed to
the CLI verbatim (the escape hatch for a flag the shim does not know
yet); `--help` renders them, and an unknown option is refused rather than
guessed at. The request's `max_steps` IS enforced by the shim, since neither CLI
has a turn cap of its own: each model call (Claude) or completed
non-reasoning item (Codex) is a step, and the CLI is torn down the moment
the ceiling is exceeded, surfacing as `AgentFailure::MaxSteps` with the
cost observed so far. The stop is graceful (SIGINT, then a grace to
flush): Claude's per-message snapshots are settled on that path; Codex
reports usage only when a turn completes and does not flush on SIGINT,
so a capped Codex run records zero cost rather than an estimate. Reports are `{"answer": …, "engine": …}` plus the
session or thread id for resume; `--schema` makes `answer` structured.
Provider credentials ride the inherited environment, exactly as the
contract prescribes. The dialects are recorded-line tests
(`shim/claude/dialect.mbt`, `shim/codex/dialect.mbt`); the fixtures pin
what each CLI emits today, so an upstream format change fails a test
rather than a workflow.

Composing engines is routing by kind: `contract_runner`'s `launch` sees
every call's `kind`, so one `match` sends `claude` calls to one shim,
`codex` calls to the other, and everything else to `openseek subrun
<kind>`. `examples/compose.mbtx` does exactly that — a keyless openseek
probe, Claude and Codex answering the same question in parallel, and
Claude judging both — in one workflow with one journal, so a second run
replays all four calls.
For in-process engines (and tests), implement one async function and
wrap it:

```moonbit nocheck
///|
let runner = @workflow.Runner(call => {
  // spawn something, await it, and account honestly:
  Finished(value=report_json, attempt={
    attempt_id,
    steps_used,
    prompt_tokens,
    completion_tokens,
    cost_usd: None, // `Double?` has no default: name it, even when unknown
  })
})
```

[openseek](https://github.com/moonbitlang/openseek)'s production adapter (its `agent_workflow` package)
maps `explore`/`review`/`echo` kinds onto `openseek subrun` child
processes and adds write-capable `worker` slices — confined git
worktrees whose outcomes are captured from git evidence, replayed by
their LOGICAL identity, and re-validated against the live registry at
replay time (a stale outcome runs live instead of lying). The dependency points engine → framework: this
module never learns openseek exists.
