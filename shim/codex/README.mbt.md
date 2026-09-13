# moonbitlang/workflow/shim/codex

Run Codex as a workflow child. This executable reads the
[child contract](../../docs/child-contract.md), drives `codex exec --json`,
and translates completed items and turns into steps, usage, and a final
report. It supports native and wasm and exposes no callable library API.

## Launch from a workflow

The machine running the shim needs the `codex` CLI on `PATH` (or a
`--command` override), configured with its normal credentials. Environment
variables are inherited. `moonx` obtains the published shim; it does not
install or authenticate Codex.

Add `moonbitlang/workflow` to your module and import
`moonbitlang/workflow` and `moonbitlang/workflow/spawn` in `moon.pkg`.
This example invokes a real agent, so documentation tests do not run it:

```moonbit nocheck
///|
async fn main {
  let wf = @workflow.Workflow(
    runner=@spawn.contract_runner(launch=_ => {
      @spawn.LaunchSpec(command="moonx", args=[
        "moonbitlang/workflow/shim/codex",
      ])
    }),
    max_calls=1,
  )
  let report = wf.agent(
    prompt="Describe the repository's public API in three sentences.",
    kind="explore",
    max_steps=8,
  )
  println(report.stringify())
}
```

An unversioned coordinate takes the latest published module; use
`moonbitlang/workflow/shim/codex@<version>` to pin it. Add a workflow journal
to reuse prior reports without launching Codex again.

## Options and sandbox selection

```sh
moonx moonbitlang/workflow/shim/codex --help
```

`--help` prints plain text before reading a request. During execution,
request and option errors are `command_error` JSONL events.

| Option | Codex mapping |
| --- | --- |
| `--command EXE` | CLI executable; default `codex`. |
| `--model NAME` | `-m NAME`; absent leaves selection to the CLI. |
| `--cwd DIR` | Working directory of the CLI process. |
| `--writable` | Selects the write-capable sandbox below. |
| `--schema FILE` | `--output-schema FILE`, unless the request supplies a schema. |
| `-- ARGS...` | Passed after the shim's options and before the positional prompt. |

The shim builds `exec --json --skip-git-repo-check -s read-only` by default.
With `kind="worker"` or `--writable`, it chooses `workspace-write`. These
are the flags this adapter requests; the CLI's configuration and host
permissions also apply. Passthrough flags can alter behavior, so keep the
JSON event output intact.

The prompt is the last positional argument. The CLI's stdin is closed from
the start so it cannot wait for additional input. The shim's own stdin stays
open as the parent's cancellation channel.

Kinds do not select different Codex tasks; `worker` selects the sandbox
policy. Input must be a string, `{query, hints?}`, or `{prompt}`. `wf.agent`
builds the supported query shape; an object containing only `task` does not.

## Reports and schema handling

The last completed `agent_message` supplies the answer. The report inside
`subrun_report` has this shape:

```json
{
  "answer": "The repository exposes ...",
  "engine": "codex",
  "thread_id": "example-thread",
  "notices": ["An optional configuration setting was ignored."]
}
```

`thread_id` is included when observed and `notices` only when nonempty.
The shim does not automatically resume that thread. Workflow journal replay
is a separate mechanism.

A request `schema` takes precedence over `--schema FILE`. The shim writes
an envelope schema to a temporary JSON file and supplies it through
`--output-schema`; a command-line schema path is passed through to Codex.
Use an absolute path when also changing `--cwd`.

With a schema, the final message is parsed as JSON and placed in `answer`.
If parsing fails it remains a string. This adapter does not perform local
JSON Schema validation. The schema describes the answer, while
`wf.agent_as[T]` decodes the complete report wrapper. Use a wrapper type with
an `answer` field, or decode that field explicitly after `wf.agent`.

## Event translation and limits

| CLI event | Adapter behavior |
| --- | --- |
| `thread.started` | Records the thread id. |
| `item.completed` with `reasoning` | Ignored for step counting. |
| `item.completed` with `error` | A notice, not a step or terminal failure. |
| Other `item.completed` | Adds a step; an `agent_message` replaces the stored answer. |
| `turn.completed` | Emits usage when input/output counters are valid. |
| `turn.failed` or top-level `error` with a message | Records a terminal failure; the first message wins. |

Steps measure completed non-reasoning, non-notice items, including commands,
file changes, tool calls, and messages. They are not a count of model calls.
The shim emits events for an item before checking `steps > max_steps`, so
the over-limit item is counted and the stop is reactive.

Usage arrives at turn completion. Prompt tokens are `input_tokens`, cache
hits are `cached_input_tokens` capped at input tokens, and misses are their
difference. The adapter emits no dollar price. In the recorded/tested
codex-cli 0.151 behavior, interrupting a turn does not flush its usage;
a capped run can therefore record zero observed tokens despite real work.
Zero here means nothing was reported, not that the run was free.

The shared [shim runtime](../README.mbt.md#run-and-classify-the-cli) sends
SIGINT on a step stop and observes late output for up to 3 seconds before
termination. The adapter emits `max_steps_exhausted` without a report.
Parent stdin EOF also tears down the CLI without a report. A request or
launch error becomes `command_error`, and a recorded terminal failure becomes
`turn_failed`. A clean exit without an agent message supplies no report;
the parent classifies it as `NoReport`.

These rules follow the implementation and recorded codex-cli 0.151.0
fixtures in [`dialect.mbt`](dialect.mbt), rather than assuming that every
future CLI release has the same format.

## Development

From the repository root, inspect local help without running an agent and
exercise the recorded classifiers:

```sh
moon run shim/codex --target native -- --help
moon test shim/codex --target native
moon test shim/codex --target wasm
```

`just shims` builds both CLI adapters for both targets. [`main.mbt`](main.mbt)
handles argv, schema files, and terminal emission;
[`dialect.mbt`](dialect.mbt) handles event interpretation. When a CLI format
changes, update its recorded fixtures and classifier in the same change.
