# The workflow child contract

This document is the normative description of the wire contract between a
workflow runner and an agent process. The framework side is the `spawn`
package of this module (`contract_run` is the one implementation; the
`contract_runner` constructor lifts it into a `Runner`). The engine side is
any executable. The reference engine is `openseek run` from
[moonbitlang/openseek](https://github.com/moonbitlang/openseek) (§8); the
`shim/claude` and `shim/codex` executables in this module are two more.

The dependency points engine → framework: this module never learns that any
particular engine exists. Everything an engine must know is on this page.

In one sentence: the runner puts a fresh result path in the child's argv,
writes one request line on its stdin, and reads the one result file the
child writes there; the child's stdout is for humans and is never read.

Three version numbers appear around this contract, and none of them moves
with another: the **request** and **result** documents below are both
version `1`; the [host handoff](host-handoff.md) that tells a hosted script
how to launch children is version `2`; and the `moonbitlang/workflow`
package has its own release version.

## 1. Process lifecycle

For one agent call the runner:

1. creates a private temporary directory and substitutes `<dir>/result.json`
   for every `{result_file}` (`@spawn.ResultFilePlaceholder`) in the argv.
   An argv that does not name `{result_file}` is a launch failure: nothing
   is spawned;
2. spawns `command args…` with the parent's environment (plus an optional
   `extra_env` overlay), `cwd` from the launch spec, stdin and stdout as
   pipes, and stderr inherited from the runner's own process (the runner
   never reads it);
3. writes exactly ONE request line (§2) on the child's stdin and keeps the
   pipe open — closing it later is the graceful-cancel signal, not the end
   of input;
4. drains the child's stdout until EOF as opaque bytes, so the child never
   blocks on a full pipe. It need not be UTF-8, or lines; nothing on it is
   ever read as a result or as usage;
5. after a clean stdout EOF, waits up to 2 000 ms for the child's exit
   status;
6. when `wall_deadline_ms` elapses first: closes stdin, keeps draining for
   `cancel_grace_ms` (default 5 000 ms) while collecting the exit status,
   then terminates the child. A `completed` result written inside the grace
   window still counts;
7. reads the result file (§3), classifies the run (§4), and removes the
   directory.

Cancellation of the CALLER (the workflow's task group being torn down) is
never folded into a terminal: the runner closes both pipes, terminates the
child, removes the directory, and re-raises the cancellation.

A child therefore has three ways to end: it exits, the deadline closes its
stdin, or the caller is cancelled. A well-behaved engine treats stdin EOF as
"stop now, write what you have, and exit": an `interrupted` result, written
within the grace window.

## 2. The request line

One JSON object, UTF-8, terminated by `\n`:

```json
{"version": 1, "request_id": "cr-7", "kind": "explore", "input": {"query": "…"}, "limits": {"max_steps": 24}}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `version` | integer | The request document's version, `1`. |
| `request_id` | string | The runner's attempt id for this launch. The child MUST echo it in its result. |
| `kind` | string | The agent kind the caller asked for — the `AgentCall.kind`, as the engine names its presets. |
| `input` | any JSON | The call's input, opaque to the framework. For `Workflow::agent` it is `{"query": …}` plus an optional `"hints"` string; `Workflow::agent_call` passes exactly what the script gave it. |
| `limits.max_steps` | integer, optional | The caller's step ceiling — the `AgentCall.max_steps`. Absent when the caller set none. |
| `schema` | JSON object, optional | A JSON Schema the report must satisfy — the `AgentCall.schema`. Present only when the caller passed one. An engine that cannot hold its report to the schema MUST refuse the request (a `failed` result), not ignore it. |

The runner sends nothing else on stdin. A child must tolerate the pipe
staying open after the line and must not wait for a second line — the only
further event on stdin is EOF.

`kind`, `input`, `max_steps`, and `schema` are also the journal's replay
identity for the call (`replay_scope` completes it; the display label is
excluded). An engine that ignores one of them on the wire and takes it from
somewhere else (argv, say) makes the journal's identity diverge from what
actually ran.

## 3. The result file

The child writes the file once, when it is over, so that a reader sees either
no file or a whole one (write a sibling, then rename it into place):

```json
{"version": 1, "request_id": "cr-7", "status": "completed", "output": {"answer": "…"}, "usage": {"prompt_tokens": 90, "completion_tokens": 10, "total_tokens": 100, "prompt_cache_hit_tokens": 0, "prompt_cache_miss_tokens": 90}, "steps": 2}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `version` | integer | The result document's version, `1`. |
| `request_id` | string | The request's `request_id`, echoed. A result for another request is refused. |
| `status` | string | `completed`, `no_report`, `max_steps_exhausted`, `context_yield`, `aborted`, `interrupted`, or `failed`. |
| `output` | any JSON | With `completed`: the report. |
| `reason` | string | With `context_yield`, `aborted`, `interrupted`, `failed`: why. |
| `usage` | object, optional | The child's cumulative totals: `prompt_tokens`, `completion_tokens`, `total_tokens`, `prompt_cache_hit_tokens`, `prompt_cache_miss_tokens`, ALL present and integral. A total, never an increment. An optional `usage.cost_usd` (a finite, non-negative number) is the engine's own price for the run; absent means unknown, never free. A usage object missing a counter, carrying a fractional one, or carrying a `cost_usd` that is not such a number makes the result malformed (§4). |
| `steps` | integer, optional | Model requests (or the engine's own step unit) the child made. |

"Integral" means a JSON number whose value is a whole integer. Other fields
are ignored. openseek's `docs/run-result.md` is the reference engine's full
description of the same document.

## 4. Classification

The run resolves to one `ContractTerminal`:

| Condition | Terminal |
| --- | --- |
| The child could not be launched: the argv names no `{result_file}`, or pipes, spawn, or the temporary directory failed | `Failed(reason)` |
| `completed` (also when it lands in the grace window after the deadline) | `Captured`, report = `output` |
| The deadline elapsed, and there is no `completed` result (none, a malformed or unreadable one, or another status) | `TimedOut` |
| `no_report` / `max_steps_exhausted` / `context_yield` | `NoReport` / `MaxSteps` / `ContextYield` |
| `aborted` / `interrupted` / `failed` | `Failed("aborted: …")` / `Failed("interrupted: …")` / `Failed(reason)` |
| No result file | `Failed("the child exited N without writing a result")`, or the runner's own failure (a broken pipe, say) |
| An unreadable or malformed file, a wrong `request_id`, an unknown `status` | `Failed(...)` |

A missing file never means success. `Captured` means a result arrived, not
that its content is acceptable — that is the caller's judgment, at the layer
that knows the report schema (`Workflow::agent` returns it verbatim; even
JSON `null` is a report). The exit status is kept beside the result
(`ContractResult.exit_code`) rather than overriding it: a `completed` result
with a nonzero exit is still `Captured`, and the status says the exit was
abnormal.

`contract_runner` maps each terminal into the workflow's lossless
`AgentOutcome`: `Captured` becomes `Finished(value, attempt)`; every other
terminal becomes `DidNotFinish(failure, attempt)` with the matching
`AgentFailure`. The attempt — id, steps, tokens, and cost — is attached on
EVERY terminal, so a timed-out child's reported spend still reaches the
budget and the journal. `attempt = None` is reserved for calls that never
launched (a human `Skipped` refusal); a failed spawn spent nothing but WAS
an attempt.

## 5. Accounting

The counters, and the price when `usage.cost_usd` states one, come from the
result's `usage` and `steps`. Nothing is observed while the child runs, so a
caller cancelled mid-run sees none. When the runner has no account from the
child (no file, a malformed file, or a result without `usage`),
`ContractResult.unaccounted` and `AgentAttempt.unaccounted` say why, and the
counters are zero. A failure before a child process started (the argv, pipes,
spawn, the temporary directory) spent nothing and is not unaccounted; any
failure after it is. `steps` is read even from a result without `usage`. A
hosted launch cancelled mid-run writes `unaccounted` on its `agent_finished`
sidecar line. `None` means the counters are the child's own totals.

## 6. Timing, environment, and argv

- `wall_deadline_ms`: `LaunchSpec.deadline_ms` when set, else
  `contract_runner`'s `deadline_ms` (default 600 000). The request write
  sits INSIDE the deadline scope: an input larger than the pipe capacity
  against a child that never reads hits the deadline instead of blocking
  forever.
- `cancel_grace_ms`: 5 000 by default, and it bounds the whole wind-down:
  flushing, and the exit status. A child still running when it ends is
  terminated, and a result it writes later does not count. The exit-status
  wait after a clean EOF is bounded at 2 000 ms; a child that closed stdout
  but lingers is terminated.
- Environment: the child inherits the runner's environment. Credentials
  that exist only in the caller's memory ride the `extra_env` overlay —
  argv is visible in `ps`, the environment is not. Never put a key in argv.
- `cwd`: the child's working directory, from the launch spec; `None` means
  the runner's own.
- argv is DEPLOYMENT configuration, not part of the contract, apart from
  `{result_file}`. The request line is self-contained by design so that a
  request never depends on engine-specific flags.

## 7. Versioning

- The request and result documents carry `version: 1`. An engine must refuse
  a request `version` it does not implement loudly — a `failed` result when
  it can echo the `request_id`, else no result, a message on stderr, and a
  nonzero exit — rather than half-parse it. The runner refuses a result
  whose `version` is not 1.
- Additive changes — a new optional request field, a new optional result
  field — do not bump the version. Both sides ignore what they do not know.
- Any change to what §2–§5 read or how they classify (renaming a field,
  changing the `usage` counter set, a new `status`) is breaking: bump the
  version, and update this document in the same change.

## 8. The reference engine: `openseek run`

`openseek run --input-format json --cancel-on-stdin-eof --kind {kind}
--result-file {result_file}` speaks this contract. It reads `kind` and
`limits.max_steps` from the request (an explicit `--max-steps` wins, so a
launch should not pass one), refuses a `schema`, and rejects a `--kind` that
disagrees with the request. On stdin EOF it cancels its turn and writes an
`interrupted` result. A child launched this way delegates no further. Its
presets:

| Kind | Needs a key | `input` | `output` of a `completed` result | Default steps |
| --- | --- | --- | --- | --- |
| `echo` | no | any JSON | the input, echoed back verbatim; no model call | — |
| `explore` | yes | `{"query": string, "hints"?: string}` — `query` non-blank | `{"schema_version": 1, "answer": string ≤ 8 000 chars, "citations": [{"file", "line"?, "note"?}] ≤ 20, "unresolved"?: string}` | 100 |
| `review` | yes | `{"goal": string, "sha"?: string, "dirty"?: bool}` — `goal` non-blank; `sha`+`dirty` describe the baseline the goal was set against | `{"schema_version", "scope": {"base", "head", "files"}, "findings": [{"file", "line"?, "severity", "category", "title", "detail", "suggestion"?}], "summary", "stats": {"files_reviewed", "findings", "build", "tests"}}` | 100 |
| `worker` | yes | `{"task", "context"?, "worker_root", "worker_admin_dir", "deny_roots": [abs paths], "allowed_paths": [non-empty], "base_oid"}` — all paths absolute, arrays non-empty | `{"schema_version", "status", "summary", "verification"}` | 300 |

Settings it takes from argv or the environment: `--model` (or
`OPENSEEK_MODEL`), `--api-url`, `--thinking`, the provider key from the
environment (`DEEPSEEK`, `KIMI`, or `GLM`, matched to the model's provider;
never `--api-key`, which is visible in `ps`), `--dir` (default: the child's
cwd, i.e. `LaunchSpec.cwd`), and `--session <id> --session-root <dir>` for a
durable child transcript. `contract_runner` passes none of these itself; a
launch adds the ones it wants. See openseek's `docs/run-result.md` for the
authoritative list.

Wall deadlines belong to the runner configuration: `contract_runner` and
`hosted` default to 600 s, regardless of kind. `worker` is write-capable and
expects a provisioned git worktree described by its input. A host-side
controller must provision that worktree, validate the changed paths, capture
git evidence, and handle integration; neither `contract_runner` nor `hosted`
supplies that controller.

Ids: `contract_runner` numbers attempts `cr-1`, `cr-2`, … per runner value;
that is the request's `request_id` and the `AgentAttempt.attempt_id`. A
hosted runner uses the host's child ids instead. openseek's own parent
runner numbers its children `<parent>-sr-N`. The journal never stores an
attempt's id as identity; it stores the call's work identity (§2) and the
outcome, attempt id included as data.

## 9. Conformance checklist for a new engine

An executable is a workflow engine when it:

1. takes the result path from its argv (the launch passes `{result_file}`
   where the engine expects it) and writes nothing else there;
2. reads one request line from stdin, refuses any `version` but 1, and
   keeps running after it, treating stdin EOF as graceful cancel;
3. writes exactly one result, once, when it is over — a sibling renamed
   into place — echoing the `request_id`, on every ending it controls:
   `interrupted` for the parent's cancel, `failed` with a reason for its
   own failures and for a request it cannot run;
4. reports `usage` as its cumulative totals, and omits it rather than
   report an unknown spend as zero.

A request it cannot parse at all has no `request_id` to echo: the engine
writes nothing, explains on stderr, and exits nonzero, and the runner
reports that the child left no result.

The `shim/claude` and `shim/codex` executables are two conforming engines.
Each wraps a foreign CLI through the shared `shim` package (`serve` reads
the request and writes the result), takes `--result-file PATH` on its argv,
and enforces `limits.max_steps` itself. A cancelled shim tears its CLI down
gracefully, settles the usage it observed, and writes `interrupted`.
`spawn/spawn_test.mbt` drives scripted `sh` children through each
classification; `shim/shim_wbtest.mbt` drives the shim runtime through
every ending it writes; openseek's `tests/cram/run-requests.md` pins the
reference engine's results, refusals, and cancellation byte for byte.

The smallest conforming engine is a shell script launched as
`sh -c SCRIPT sh {result_file}`:

```sh
read request
id=$(printf '%s' "$request" | sed 's/.*"request_id":"\([^"]*\)".*/\1/')
printf '{"version":1,"request_id":"%s","status":"completed","output":{"answer":42}}' "$id" > "$1.tmp"
mv "$1.tmp" "$1"
```
