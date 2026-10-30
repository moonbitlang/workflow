# moonbitlang/workflow/shim/claude

Run Claude Code as a workflow child. This executable speaks the
[child contract](../../docs/child-contract.md): it reads one
request line on stdin, drives
`claude -p --output-format stream-json --verbose`, reads that stream for the
answer, usage, and steps, and writes one result file. It supports native and
wasm and exposes no callable library API.

## Launch from a workflow

The machine running the shim needs `claude` on `PATH` (or a `--command`
override), configured with the credentials and access it normally needs.
The CLI inherits the process environment. `moonx` obtains the published
shim; it does not install or authenticate Claude Code.

Add `moonbitlang/workflow` to your module and import
`moonbitlang/workflow` and `moonbitlang/workflow/spawn` in `moon.pkg`.
This snippet is a real agent invocation, so it is not run as a documentation
test:

```moonbit nocheck
///|
async fn main {
  let wf = @workflow.Workflow(
    runner=@spawn.contract_runner(launch=_ => {
      @spawn.LaunchSpec(command="moonx", args=[
        "moonbitlang/workflow/shim/claude",
        "--result-file",
        @spawn.ResultFilePlaceholder,
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

The runner replaces `{result_file}` (`@spawn.ResultFilePlaceholder`) with a
fresh private path per launch and reads the result from it; the shim's
stdout carries nothing. An unversioned `moonx` coordinate uses the latest
published module. Pin it
as `moonbitlang/workflow/shim/claude@<version>` when reproducing a run. A
workflow with a journal can replay a prior report without launching the CLI.

## Options and tool policy

All options, `--result-file` included, precede the passthrough separator:

```sh
moonx moonbitlang/workflow/shim/claude --help
```

`--help` prints plain text before reading a request. An option error, or a
request that names no `request_id`, is printed on stderr and the shim exits
nonzero without a result; any other malformed request is a `failed` result.
The shared options are:

| Option | Claude mapping |
| --- | --- |
| `--result-file PATH` | Required: where the result file goes. |
| `--command EXE` | CLI executable; default `claude`. |
| `--model NAME` | `--model NAME`; absent leaves model selection to the CLI. |
| `--cwd DIR` | Working directory of the CLI process. |
| `--writable` | Enables the write-capable policy below. |
| `--schema FILE` | Reads the file and passes its text via `--json-schema`. |
| `-- ARGS...` | Passed to Claude before the shim's tool list. |

By default the shim supplies `--disallowedTools` for `Edit`, `Write`,
`MultiEdit`, `NotebookEdit`, and `Bash`. With `kind="worker"` or
`--writable`, it supplies `--permission-mode acceptEdits` and
`--allowedTools` for that list. This describes the flags the shim sets;
installed tools, CLI configuration, and host permissions still determine
what the process can do. Passthrough flags can change behavior, so preserve
the required stream output format when adding them.

Kinds do not select separate Claude workflows. They are forwarded in the
request and `worker` selects the tool policy. Input must still yield a
prompt: `{query, hints?}`, `{prompt}`, or a string. Use `wf.agent` for that
shape; arbitrary worker objects with only a `task` field are not accepted.

## Reports and structured output

A `completed` result's `output`, which the parent receives as the report:

```json
{
  "answer": "The repository exposes ...",
  "engine": "claude",
  "session_id": "example-session",
  "num_turns": 1,
  "cost_usd": 0.01
}
```

This is an illustrative shape, not a fixed price. `answer` and `engine` are
present for a report; the other fields appear when the CLI supplies them.
Session ids are metadata for callers; the shim does not automatically
resume a CLI session. Journal replay is handled by the workflow.

An object-valued request `schema` takes precedence over `--schema FILE` and
is serialized into `--json-schema`. A successful `structured_output` becomes
`answer`; otherwise the result text becomes `answer`. The schema describes
that answer, not the shim's outer report object.

Consequently, `wf.agent_as[T]` needs a `T` that describes the report wrapper,
for example a struct with an `answer` field of your desired type. Alternatively,
call `wf.agent` and decode `report["answer"]` at your own boundary. The shim
does not locally validate the answer against JSON Schema.

## Steps, usage, and stopping

Each distinct Claude assistant message id counts as one step. Thinking,
text, and tool-use content blocks sharing a message id do not add separate
steps. After counting the observed step, the shim requests a stop when
`steps > limits.max_steps`; the over-limit work has already happened and is
counted. This is a reactive ceiling, not a guarantee of at most N model
calls.

The result's `usage` is the final result's totals when available. Prompt
tokens include fresh input, cache creation, and cache reads; cache reads are
hits, and fresh input plus cache creation are misses. The final result's
output tokens and price (`total_cost_usd`, as `usage.cost_usd`) are used as
supplied. If no result arrives, the last usage snapshot for each message is
summed as a fallback, without an invented price; with no snapshot either,
the result carries no `usage`. `steps` is the number of distinct messages.

The shared [shim runtime](../README.mbt.md#run-and-classify-the-cli) sends
SIGINT and grants a 3-second flush period on a step stop and on the
parent's cancel, and late usage still counts. The endings:

| How the run ended | Result `status` |
| --- | --- |
| A successful `result` line | `completed`, with the report as `output` |
| The step ceiling, or Claude's own `error_max_turns` | `max_steps_exhausted` |
| Parent stdin EOF | `interrupted` |
| An error `result`, a launch failure, an unreadable `--schema`, or a nonzero exit without a result | `failed`, with the reason |
| A clean exit without a result | `no_report` |

The behavior above follows the classifier and recorded Claude Code
2.1.258 fixtures in [`dialect.mbt`](dialect.mbt); it is not a claim about
every future CLI release.

## Development

From the repository root, check the local executable without launching an
agent, then run its recorded dialect tests:

```sh
moon run shim/claude --target native -- --help
moon test shim/claude --target native
moon test shim/claude --target wasm
```

`just shims` builds both adapters for both targets. [`main.mbt`](main.mbt)
wires the schema and process execution into `@shim.serve`;
[`dialect.mbt`](dialect.mbt) classifies recorded stdout lines and builds
the report and the result. Update fixtures and classifier together when CLI
output changes.
