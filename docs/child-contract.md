# The workflow child contract (v1)

This document is the normative description of the wire contract between a
workflow runner and an agent process. The framework side is the `spawn`
package of this module (`contract_run` is the one implementation; the
`contract_runner` constructor lifts it into a `Runner`). The engine side is
any executable. The reference engine is `openseek subrun <kind>` from
[moonbitlang/openseek](https://github.com/moonbitlang/openseek), and the
second half of this document records what that engine actually honours —
the part of the contract that was implicit until now.

The dependency points engine → framework: this module never learns that any
particular engine exists. Everything an engine must know is on this page.

## 1. Process lifecycle

For one agent call the runner:

1. spawns `command args…` with the parent's environment (plus an optional
   `extra_env` overlay), `cwd` from the launch spec, stdin and stdout as
   pipes, stderr inherited from the runner's own process (the runner never
   reads it);
2. writes exactly ONE request line on the child's stdin and keeps the pipe
   open — closing it later is the graceful-cancel signal, not the end of
   input;
3. drains the child's stdout line by line until EOF, classifying every line
   as described in §3 and §4;
4. after a clean stdout EOF, waits up to 2 000 ms for the child's exit
   status (§5 says what a nonzero status means);
5. when `wall_deadline_ms` elapses first: closes stdin, keeps draining for
   `cancel_grace_ms` (default 5 000 ms; a report that lands inside the
   grace window still counts), then terminates the child.

Cancellation of the CALLER (the workflow's task group being torn down) is
never folded into a terminal: the runner closes both pipes, terminates the
child, and re-raises the cancellation.

A child therefore has three ways to end: it closes stdout (normally by
exiting), the deadline closes its stdin, or the caller is cancelled. A
well-behaved engine treats stdin EOF as "stop now, flush what you have, and
exit"; it may still print a report during the grace window.

## 2. The request line (stdin)

One JSON object, UTF-8, terminated by `\n`:

```json
{"workflow_contract": 1, "id": "cr-7", "kind": "explore", "max_steps": 24, "input": {"query": "…"}}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `workflow_contract` | integer | The contract MAJOR version. This document is version 1. |
| `id` | string | The runner's attempt id for this launch (informational: the child may log it). |
| `kind` | string | The agent kind the caller asked for — the `AgentCall.kind`. |
| `max_steps` | integer, optional | The caller's step ceiling — the `AgentCall.max_steps`. Absent when the caller set none. |
| `schema` | JSON object, optional | A JSON Schema the report must satisfy — the `AgentCall.schema` the caller passed. An engine that can constrain its model to a shape should apply it; the caller validates the report regardless, so an engine that cannot may ignore it. Absent when the caller passed none. |
| `input` | any JSON | The call's input, opaque to the framework. For `Workflow::agent` it is `{"query": …}` plus an optional `"hints"` string; `Workflow::agent_call` passes exactly what the script gave it. |

The runner sends nothing else on stdin. A child must tolerate the pipe
staying open after the line and must not wait for a second line — the only
further event on stdin is EOF.

`kind`, `input`, `max_steps`, and `schema` are also the journal's replay identity for
the call (`replay_scope` completes it; the display label is excluded). An
engine that ignores one of them on the wire and takes it from somewhere else
makes the journal's identity diverge from what actually ran — see §7 for
the case that matters in practice.

## 3. The event stream (stdout)

The child writes JSON objects, one per line. A line that does not parse as
JSON is skipped (a leaky tool subprocess must not poison the run). An object
with a top-level `subrun_report` key is the report (§4). Every other object
is an event; the runner looks at its `event` tag and reads only the fields
below. Unknown events, and extra fields on known ones (`timestamp`,
`level`, `source`, …), are ignored.

| `event` | Fields read | Effect on the runner |
| --- | --- | --- |
| `agent_step` | `step`: integral number | `steps_used = max(steps_used, step)` |
| `usage` | `usage.prompt_tokens`, `usage.completion_tokens`, `usage.total_tokens`, `usage.prompt_cache_hit_tokens`, `usage.prompt_cache_miss_tokens`: ALL present and integral | `prompt_tokens += …`, `completion_tokens += …`. A usage object missing any of the five fields, or carrying a fractional value, is ignored WHOLE — never partially charged. An optional `usage.cost_usd` (a finite, non-negative number; fractional) is summed into the attempt's `cost_usd`; absent means unknown, never free. A PRESENT `cost_usd` that is not such a number invalidates the whole line, tokens included — the same rule as a bad token field. |
| `max_steps_exhausted` | — | Terminal candidate `MaxSteps` |
| `context_yield` | `to_sequence`: integral number, `answer`: string | Terminal candidate `ContextYield` |
| `turn_failed` | `error`: string | Terminal candidate `Failed(error)` |
| `agent_setup_failed` | `error`: string | Terminal candidate `Failed(error)` |
| `command_error` | `error`: string | Terminal candidate `Failed(error)` |
| `agent_aborted` | `reason`: string | Terminal candidate `Failed(reason)` |

"Integral number" means a JSON number whose value is a whole integer;
`1.5` is not a step or a token count and the line is ignored.

The tags are the contract, not any engine's type vocabulary — they happen
to coincide with `moonbitlang/openseek`'s protocol events because that
engine was the first speaker. A new engine emits only what it has: an
engine with no step counter emits no `agent_step` lines and is simply
accounted as zero steps.

Costs are observed AS the child streams: pass a `ContractProgress` to
`contract_run` to keep visibility into a run that ends by cancellation.

## 4. The report line

```json
{"subrun_report": <any JSON>}
```

The value is the agent's result. The framework treats it as opaque JSON:
whether its CONTENT is acceptable is the caller's judgment, at the layer
that knows the report schema (`Workflow::agent` returns it verbatim). A
child emits exactly one report, as its LAST line — a report is the child's
declaration that it finished. The runner stops treating the run as a
failure the moment a report arrives, whatever events preceded it; if
several report lines arrive, the last one wins.

## 5. Terminal classification

After the child ends, the run resolves to one `ContractTerminal`, in this
order of precedence:

| Precedence | Condition | Terminal |
| --- | --- | --- |
| 1 | A report line arrived | `Captured` |
| 2 | A failure event arrived (`turn_failed`, `agent_setup_failed`, `command_error`, `agent_aborted`), OR the child could not be spawned, OR its pipes failed, OR it exited nonzero with neither report nor failure event | `Failed(reason)` |
| 3 | The wall deadline elapsed | `TimedOut` |
| 4 | `max_steps_exhausted` arrived | `MaxSteps` |
| 5 | `context_yield` arrived | `ContextYield` |
| 6 | Otherwise (clean exit, no report) | `NoReport` |

A nonzero exit status matters only when the child said nothing about why:
an engine that already emitted `turn_failed` may exit with any status. An
engine that crashes (panic, signal) emits nothing, and the exit status is
what keeps the runner from misreading a crash as `NoReport`.

`contract_runner` maps each terminal into the workflow's lossless
`AgentOutcome`: `Captured` becomes `Finished(value, attempt)`; every other
terminal becomes `DidNotFinish(failure, attempt)` with the matching
`AgentFailure`. The attempt — id, steps, tokens, and cost observed — is
attached on EVERY terminal, so a timed-out child's spend still reaches the budget and
the journal. `attempt = None` is reserved for calls that never launched (a
human `Skipped` refusal); a failed spawn observed zero cost but WAS an
attempt.

## 6. Timing, environment, and argv

- `wall_deadline_ms`: `LaunchSpec.deadline_ms` when set, else
  `contract_runner`'s `deadline_ms` (default 600 000). The request write
  sits INSIDE the deadline scope: an input larger than the pipe capacity
  against a child that never reads hits the deadline instead of blocking
  forever.
- `cancel_grace_ms`: 5 000 by default. The exit-status wait after a clean
  EOF is bounded at 2 000 ms; a child that closed stdout but lingers is
  terminated.
- Environment: the child inherits the runner's environment. Credentials
  that exist only in the caller's memory ride the `extra_env` overlay —
  argv is visible in `ps`, the environment is not. Never put a key in argv.
- `cwd`: the child's working directory, from the launch spec; `None` means
  the runner's own.
- argv is DEPLOYMENT configuration, not part of the contract. The request
  line is self-contained by design so that a request never depends on
  engine-specific flags. In practice an engine may still take some of its
  settings from argv — which is exactly what §7 is about.

## 7. The reference engine: what `openseek subrun` honours

`openseek subrun <kind>` (source: `cmd/openseek/subrun.mbt` in the openseek
repository; parent-side wrapper `agent_subrun.run_subrun`; workflow
adapter `agent_workflow.subrun_runner`) speaks this contract natively. It
also has behaviour the contract text above leaves open. This section makes
that behaviour explicit so that a script driving `openseek` directly through
`contract_runner` gets the run it asked for.

### 7.1 Which envelope fields the engine reads

| Envelope field | What openseek does with it |
| --- | --- |
| `workflow_contract` | `1` is accepted. Any other value is rejected with a `command_error` event (`unsupported workflow_contract version N`) and no report — the runner sees `Failed`. |
| `input` | The ONLY field the engine consumes. It is handed to the kind's dispatcher unchanged. |
| `kind` | IGNORED. The kind comes from argv: the positional after `subrun`. |
| `max_steps` | IGNORED. The enforced step ceiling comes from `--max-steps` on argv (or the `OPENSEEK_MAX_STEPS` environment variable), else the kind's default. |
| `id` | IGNORED. A child's durable session id, when it has one, comes from `--session`. |
| `schema` | IGNORED. The engine's kinds have fixed report types (§7.3); a caller wanting a shape from openseek decodes the fixed report. The Claude and Codex shims in the library DO apply it. |

A bare input line without the envelope (`{"query": …}` directly) is also
accepted, for the engine's own pre-contract callers and for hand-driven
children. Sending the v1 envelope is the supported form.

**The consequence that bites:** a launch spec must MIRROR the call's kind
and step ceiling onto argv, or the journal will record a `max_steps` the
child never enforced (its scouts run to the kind default of 100 steps).
`agent_workflow.subrun_runner` does this for you; a script that builds the
`LaunchSpec` itself must do the same:

```moonbit nocheck
///|
let runner = @spawn.contract_runner(launch=call => {
  let argv = ["subrun", call.kind]
  if call.max_steps is Some(steps) {
    argv.push("--max-steps")
    argv.push("\{steps}")
  }
  { command: "openseek", args: argv, cwd: None, extra_env: None, deadline_ms: None }
})
```

### 7.2 argv and environment the engine takes its settings from

All of these are root-level options of the `openseek` binary; they may
appear before or after `subrun <kind>`.

| Setting | argv | environment | Default |
| --- | --- | --- | --- |
| kind | positional `subrun <kind>` | — | required |
| step ceiling | `--max-steps N` | `OPENSEEK_MAX_STEPS` | per kind (§7.3) |
| model | `--model NAME` | `OPENSEEK_MODEL` | `deepseek-v4-flash` |
| endpoint | `--api-url URL` | `OPENSEEK_API_URL` | provider default |
| thinking | `--thinking no\|high\|max` | `OPENSEEK_THINKING` | `high` |
| provider key | `--api-key` (avoid: visible in `ps`) | `DEEPSEEK`, `KIMI`, or `GLM`, matched to the selected model's provider | required for model-driven kinds |
| workspace | `--dir PATH` | — | `.` (the child's cwd, i.e. `LaunchSpec.cwd`) |
| durable child session | `--session <id> --session-root <dir>` | — | none: the child's transcript stays in memory |

The engine's own parent runner appends `--session <parent>-sr-N
--session-root <root>` when the parent session is durable, so child
transcripts land as siblings of the parent's session and session tooling
finds them. `contract_runner` does not: a script wanting durable child
transcripts passes those flags itself.

### 7.3 Kinds

| Kind | Needs a key | `input` schema | Report (`subrun_report`) | Default steps | Adapter deadline |
| --- | --- | --- | --- | --- | --- |
| `echo` | no | any JSON | the input, echoed back verbatim; the child first emits one `agent_step` (step 1) and one `usage` (7 prompt / 3 completion / 10 total tokens) | — | 600 s |
| `explore` | yes | `{"query": string, "hints"?: string}` — `query` non-blank | `{"schema_version": 1, "answer": string ≤ 8 000 chars, "citations": [{"file", "line"?, "note"?}] ≤ 20, "unresolved"?: string}` | 100 | 600 s |
| `review` | yes | `{"goal": string, "sha"?: string, "dirty"?: bool}` — `goal` non-blank; `sha`+`dirty` describe the baseline the goal was set against | `{"schema_version", "scope": {"base", "head", "files"}, "findings": [{"file", "line"?, "severity", "category", "title", "detail", "suggestion"?}], "summary", "stats": {"files_reviewed", "findings", "build", "tests"}}` | 100 | 900 s |
| `worker` | yes | `{"task", "context"?, "worker_root", "worker_admin_dir", "deny_roots": [abs paths], "allowed_paths": [non-empty], "base_oid"}` — all paths absolute, arrays non-empty | `{"schema_version", "status", "summary", "verification"}` | 300 | 2 700 s |

"Adapter deadline" is the wall deadline `agent_workflow.subrun_runner`
applies per kind when the caller sets none; `contract_runner` on its own
uses its flat default. `worker` is write-capable and expects a provisioned
git worktree described by its input: drive it through
`agent_workflow.worker`, which provisions the worktree, confines it, and
captures the outcome from git evidence, rather than through a raw
`contract_runner` call.

Input validation: `worker` geometry and a blank `review` goal are reported
as a `command_error` event BEFORE any key is required, so a miswired script
gets the exact defect even keylessly; an unknown kind is a `command_error`
too. `explore` checks the key first, and a blank `query` then produces no
report at all — the runner sees `NoReport`, not `Failed`.

### 7.4 How the engine ends

- Every handled failure is an EVENT followed by a normal exit (status 0):
  the engine never `exit()`s from inside its logging scope, because the
  event queue drains asynchronously and an early exit would discard the
  very line the runner classifies on. A nonzero status therefore means a
  crash.
- The report is written after the event log is closed, through the same
  stdout writer, so it is the final line by construction.
- On stdin EOF the engine cancels its in-flight turn (the loop records an
  interruption and tears its own tool subprocesses down) and exits WITHOUT
  a report. From the runner's side that shows up as `TimedOut` when the
  runner closed stdin for the deadline, and as a re-raised cancellation
  when the caller was cancelled.
- The engine's model-driven kinds run in a per-launch scratch directory
  (a temp "lab" where the otherwise read-only child may scaffold and run
  code to verify a claim), removed on exit. The workspace itself stays
  read-only for these kinds; only `worker` writes to its worktree.

### 7.5 Ids

Three id spaces exist and none of them need to agree:

- `contract_runner` numbers attempts `cr-1`, `cr-2`, … per runner value
  and reports them as `AgentAttempt.attempt_id`; this is also the envelope
  `id`.
- openseek's own parent runner numbers sub-runs `sr-1`, `sr-2`, … per
  engine process (with a floor so a resumed parent never reuses a child
  session id already on disk) and uses them for its `subrun_started` /
  `subrun_finished` bracket and for `<parent>-sr-N` child sessions.
- The journal never stores an attempt's id as identity; it stores the
  call's work identity (§2) and the outcome, attempt id included as data.

## 8. Versioning

- `workflow_contract` is the major version. An engine must reject a major
  it does not implement loudly (a `command_error` event, no report) rather
  than half-parse the request.
- Additive changes — a new optional envelope field, a new event tag, extra
  fields on an existing event — do not bump the major. Both sides ignore
  what they do not know.
- Any change to what §3–§5 read or how they classify (renaming
  `subrun_report`, changing the `usage` field set, reordering precedence)
  is breaking: bump the major, and update this document in the same
  change.

## 9. Conformance checklist for a new engine

An executable is a workflow engine when it:

1. reads one line from stdin, parses the v1 envelope, and rejects any other
   `workflow_contract` with a `command_error` event;
2. keeps running after that line and treats stdin EOF as graceful cancel;
3. writes only JSON lines to stdout while running (anything else is
   skipped, but a JSON line with a stray top-level `subrun_report` key would
   be taken as the report);
4. accounts its cost with `usage` (all five fields, integral) and
   `agent_step` events, if it has such counters;
5. explains how it degraded with one of the failure events before exiting
   normally, and never emits a report in that case;
6. emits exactly one `{"subrun_report": …}` line, last, when it finished.

The scripted-`sh` children in `spawn/spawn_test.mbt` are executable
examples of the terminals a child can drive on its own — `Captured`,
`NoReport`, `MaxSteps`, `Failed` (`TimedOut` and `ContextYield` are the
runner's and the engine's to raise); openseek's `tests/cram/subrun.md` pins the
reference engine's echo, error, and worker-validation lines byte for byte.
The `shim/claude` and `shim/codex` executables in this module are two
further conforming engines: each wraps a foreign CLI, reads the envelope
through the shared `shim` package, and additionally enforces the request's
`max_steps` itself (§7.1's argv caveat does not apply to them — they read
`kind` and `max_steps` from the envelope).
The smallest conforming engine is a shell script:

```sh
read line
printf '{"event":"agent_step","step":1}\n'
printf '{"event":"usage","usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":7}}\n'
printf '{"subrun_report": {"answer": 42}}\n'
```
