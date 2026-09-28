# moonbitlang/workflow/spawn

Run a child process as a workflow agent. This package owns the parent side
of the [child contract](../docs/child-contract.md): send one request, read
the child's result and account its usage, and tear it down on timeout or
cancellation. It supports native and wasm.

A child hands back its result over one of two transports, which the launch
chooses. With `transport=ResultFile` it writes ONE result file, whose path
the runner substitutes for `{result_file}` in its argv, and its stdout is
for humans; OpenSeek's `openseek run` and this module's
[shims](../shim/README.mbt.md) speak it. The default, `StdoutEvents`,
streams JSONL events and a final report line on stdout instead.

Use `contract_runner` when building a workflow. Use `contract_run` when an
adapter needs the raw terminal, its own request id, live progress counters,
or access to parsed stdout lines. For a host-supplied launch configuration,
see [`hosted`](../hosted/README.mbt.md).

## Add a process runner

After `moon add moonbitlang/workflow`, import both packages in your `moon.pkg`:

```moonbit nocheck
import {
  "moonbitlang/workflow",
  "moonbitlang/workflow/spawn",
}

supported_targets = "native+wasm"
```

This checked example uses only `sh` and its builtins. It launches a real
child, which echoes the request's id in the result file it writes; the
runner accounts its usage and returns its report without model credentials.

```mbt check
///|
async test "a shell child returns an accounted workflow report" {
  // `sh -c CHILD sh {result_file}`: the result path arrives as `$1`.
  let child =
    #|read request
    #|id=$(printf '%s' "$request" | sed 's/.*"request_id":"\([^"]*\)".*/\1/')
    #|printf '{"version":1,"request_id":"%s","status":"completed","output":{"answer":"ready"},"usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":7},"steps":1}' "$id" > "$1"
  let wf = @workflow.Workflow(
    runner=@spawn.contract_runner(launch=_ => {
      @spawn.LaunchSpec(
        command="sh",
        args=["-c", child, "sh", @spawn.ResultFilePlaceholder],
        transport=ResultFile,
      )
    }),
    max_calls=1,
  )
  assert_eq(wf.agent(prompt="Are you ready?", kind="echo"), {
    "answer": "ready",
  })
  assert_eq(wf.calls_made(), 1)
  assert_eq(wf.tokens_spent(), 10)
}
```

`launch` runs once per live call and receives the entire `AgentCall`. It can
route by `kind`, choose an executable, or derive argv from the call. A replay
served by the workflow never invokes `launch`.

| `LaunchSpec` field | Behavior |
| --- | --- |
| `command`, `args` | Required executable and argument array. Arguments are passed directly, without shell expansion. |
| `cwd` | Child working directory; omitted means inherited. |
| `extra_env` | Overrides or adds to the inherited environment. |
| `deadline_ms` | Overrides the runner's deadline for this launch. |
| `transport` | `ResultFile` (argv must name `{result_file}`) or the default `StdoutEvents` (argv must not). A mismatch is a `Failed` launch. |

The runner default is `deadline_ms=600_000` (10 minutes). Credentials belong
in the environment. A CLI that does not speak the contract needs an adapter,
such as [`shim/claude`](../shim/claude/README.mbt.md) or
[`shim/codex`](../shim/codex/README.mbt.md).

For example, OpenSeek's presets, one `openseek run` child per call:

```moonbit nocheck
///|
let runner : @workflow.Runner = @spawn.contract_runner(launch=call => {
  @spawn.LaunchSpec(
    command="openseek",
    args=[
      "run",
      "--input-format",
      "json",
      "--cancel-on-stdin-eof",
      "--kind",
      call.kind,
      "--result-file",
      @spawn.ResultFilePlaceholder,
    ],
    transport=ResultFile,
  )
})
```

The request carries the kind, the input, and `limits.max_steps`; argv holds
only engine settings (OpenSeek also checks `--kind` against the request).

## The result-file transport

The runner creates a private directory per launch, substitutes its
`result.json` for `{result_file}`, and writes one request line on stdin:
`{"version": 1, "request_id", "kind", "input", "limits"?: {"max_steps"},
"schema"?}`. stdin stays open; EOF is the cancellation signal. stdout is
drained unread. When the child is done, the result file is the whole
account: `status` (`completed` with `output`, `no_report`,
`max_steps_exhausted`, or `context_yield` / `aborted` / `interrupted` /
`failed` with a `reason`), and optionally `usage` (the five counters, plus
`cost_usd` when the engine prices its work) and `steps`. A result must echo
the request's `request_id`.

A `completed` result is `Captured`, even when it lands in the deadline's
grace window; otherwise the deadline wins, as `TimedOut`. No file, or an
unreadable or malformed one, is `Failed` — never success. Because nothing is
observed while the child runs, a result without `usage` (or no result at
all) leaves the spend unknown, and `ContractResult.unaccounted` says why.
[Contract §10](../docs/child-contract.md#10-transport-2-the-result-file)
specifies the documents.

## The event-stream transport

```mermaid
sequenceDiagram
  participant W as Workflow
  participant R as spawn
  participant C as Child process
  W->>R: AgentCall
  R->>C: One JSON request line
  Note over R,C: Keep stdin open<br/>EOF cancels the child
  C-->>R: agent_step and usage lines
  alt Normal completion
    C-->>R: subrun_report, then stdout EOF
  else Wall deadline
    R->>C: Close stdin
    Note over R,C: Grace period to flush, a report still counts
    R->>C: Terminate if still running
  end
  R-->>W: AgentOutcome with observed usage
```

Under `StdoutEvents`, the request includes `workflow_contract: 1`, `id`,
`kind`, `input`, and optional `max_steps` and `schema`. Engine options remain in argv. `max_steps`
is forwarded for the child to enforce; this runner enforces elapsed time.
Never make a child wait for stdin EOF before processing the request: EOF is
the cancellation signal. Diagnostics may go to stderr, which is inherited.

The deadline includes writing the request as well as reading stdout. On a
deadline, stdin closes and the child gets 5 seconds of grace by default.
Normal stdout EOF is followed by a bounded, 2-second exit-status wait.
These teardown periods mean a deadline is not a strict bound on the total
duration of `contract_run`.

External cancellation follows a different path: teardown completes and the
cancellation is re-raised. It does not return `TimedOut` or another terminal.

### Terminal precedence and accounting

Under `StdoutEvents`, if multiple signals arrive, the first applicable row
determines the result:

| Priority | `ContractTerminal` | Evidence |
| --- | --- | --- |
| 1 | `Captured` | A `subrun_report` line arrived, even during deadline grace. |
| 2 | `Failed(reason)` | A classified failure event, spawn/pipe error, or observed nonzero exit without a report. |
| 3 | `TimedOut` | The wall deadline expired without higher-priority evidence. |
| 4 | `MaxSteps` | `max_steps_exhausted` was emitted. |
| 5 | `ContextYield` | A valid `context_yield` event was emitted. |
| 6 | `NoReport` | The stream ended without any of these signals. |

`Captured` means a report arrived, not that its content passed validation;
even JSON `null` is a report. The workflow adapter maps it to `Finished` and
the other terminals to `DidNotFinish`, retaining observed usage in either
case. It assigns attempt ids `cr-1`, `cr-2`, and so on per runner instance;
these are not globally unique session ids.

Steps are the maximum integral `agent_step.step` seen. Token usage is the
sum of valid `usage` lines, each of which must supply all five integral
counters shown in the example. An invalid counter or an invalid optional
`cost_usd` discards the whole usage line. Prices are summed only when
reported; absent prices remain `None`. Blank and non-JSON lines are ignored.
The [contract](../docs/child-contract.md) specifies the full event shapes.

## Using the lower-level API

```mbt check
///|
async test "inspect a no-report terminal directly" {
  let progress = @spawn.ContractProgress()
  let result = @spawn.contract_run(
    command="sh",
    args=["-c", "read request; exit 0"],
    input={ "query": "probe" },
    kind="echo",
    id="probe-1",
    wall_deadline_ms=5_000,
    progress~,
  )
  assert_true(result.terminal is @spawn.NoReport)
  assert_eq(result.report, None)
  assert_eq(progress.steps, 0)
}
```

`contract_run` additionally accepts `cancel_grace_ms` (default 5,000),
`observe_line`, and `progress`. The synchronous `observe_line` callback sees
every successfully parsed JSON line before classification. Use a fresh
`ContractProgress()` for each call: its mutable counters are updated in
place and remain available if cancellation unwinds past the return value.

When reports refer to resources that can disappear, pass `validate_replay`
to `contract_runner`. Return `Serve(outcome)` after checking or refreshing
the resource, or `Rerun` to reject that journal candidate. The core owns
candidate selection; see [replay](../README.mbt.md#replay-crash-resume-and-pay-only-for-new-work).

## Development

[`contract.mbt`](contract.mbt) implements framing and process lifetime;
[`exports.mbt`](exports.mbt) defines the live progress API.
[`spawn_test.mbt`](spawn_test.mbt) covers scripted child processes, usage,
terminal precedence, deadlines, and cancellation.

From the repository root:

```sh
moon test spawn --target native
moon test spawn --target wasm
```
