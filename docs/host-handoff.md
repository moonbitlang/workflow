# The host handoff

How a workflow running inside a sandbox is told what it may launch.

`contract_runner` covers the outward direction: a workflow starting a child
process over the [child contract](child-contract.md). This document covers the
inward one. A script that runs under a sandbox — an agent's scripting tool, a
CI step, any process that executes code it did not write — cannot be allowed to
choose the things that make its children accountable. The host that launched
it chooses them, before the script starts, and says so through one environment
variable.

## `WORKFLOW_HOST`

One JSON document. A family of variables was rejected deliberately: a handoff
is all-or-nothing, and a script that read four of five names would launch
children the host never reserved. The reader **fails closed** — any missing
required field, or an unknown `v`, yields no context at all rather than a
partial one.

```json
{
  "v": 1,
  "exe": "/opt/engine",
  "child_args": ["subrun", "{kind}", "--session", "{child}", "--session-root", "/store"],
  "child_id": "run7-sr-{n}",
  "ids": [5, 32],
  "journal": "/store/run7-wf-5.jsonl",
  "events": "/store/run7-wf-5.events.jsonl",
  "cwd": "/store",
  "deadline_ms": 600000
}
```

| field | required | meaning |
|---|---|---|
| `v` | yes | Handoff version: `1`, or `2` (below). Anything else is refused. |
| `transport` | with `v: 2` | `"stdout_events"` or `"result_file"`: how each child hands back its result ([child contract §10](child-contract.md#10-transport-2-the-result-file)). Version 1 is always `"stdout_events"`. |
| `exe` | yes | The engine to spawn. An absolute path is strongly advised: a sandbox policy that admits programs by exact path then admits *this* binary and not a same-named one earlier in `PATH`. |
| `child_args` | yes | The argv for one child, as a non-empty array of strings. `{kind}` is replaced by the call's kind and `{child}` by the rendered child id, in every token. With the `result_file` transport it must also name `{result_file}`, which the runner replaces with a fresh private path per launch; with `stdout_events` it must not. A template that disagrees with its transport is refused. |
| `child_id` | yes | How this host names a child. Must contain `{n}`, which is replaced by the child's ordinal; a template that consumed no ordinal would name every child alike. |
| `ids` | yes | `[first, count]`, both positive: the ordinals this script may use. It is also the **launch ceiling** — see below. |
| `journal` | no | Where to append the ledger of resolved calls. Absent means an in-memory journal that dies with the process. |
| `events` | no | Where to append the sidecar of launch brackets. Absent means no sidecar. |
| `cwd` | no | The child's working directory. |
| `deadline_ms` | no | Wall deadline per child. Default 600 000. |

## Host-specific extensions

Hosts may add namespaced top-level fields, for example
`"openseek": {"audit": {"goal": "ship the parser"}}`. `ctx.extension("openseek")`
returns that value as `Json?`; the host and its scripts own its schema and
validation. The library preserves arbitrary JSON values without interpreting
them. Missing fields return `None`; explicit `null` returns `Some(Null)`.
Reserved fields in the table above are not extensions and are never returned
by this accessor. Hosts should use their own namespace to avoid collisions
with future common fields. Existing handoffs need no changes; `v` remains 1.

## What the host must guarantee

**The block is disjoint.** The ordinals in `ids` must not be handed to anything
else — including the host's *own* children, if it names them the same way. The
right implementation is one allocator per session that both draw from. Two
independent counters would name a script's child and a host-launched child
alike, and the second to write its record would land on the first's.

**The block is the ceiling.** A script is opaque to its host: one invocation
can loop. Nothing else bounds how many children it starts, and unattended runs
execute for hours. `count` is that bound. A call past the end of the block is
refused with `Skipped` rather than launched without an id, because a child with
no record is precisely the failure this contract exists to prevent.

**The coordinates are chosen, not discovered.** A reader watching the run does
not find the ledger; it is told where the ledger is, by the host that chose the
path. That is why the handoff carries paths and an ordinal range: they let the
host announce, before the script produces anything, exactly which files and
which child ids will belong to this run.

## What the script gets

`@hosted.context()` reads the variable, or returns `None` when there is none —
an ordinary state, not an error: a script run by hand has nothing to delegate
to and should do its own work.

`ctx.run(wf => ...)` yields a `Workflow` whose `Runner` spawns `exe` with the
substituted argv, journals to `journal`, and writes two sidecar lines per
launch:

```json
{"event":"agent_started","child":"run7-sr-5","kind":"explore","label":"scout:x"}
{"event":"agent_finished","child":"run7-sr-5","status":"captured","steps":12,"tokens":3400}
```

When the runner could not get the child's own account of its spend (a
`result_file` child that died without a result, say), the finish line carries
`"unaccounted": "<why>"` and the counters are only what was observed, as the
journal's `AgentAttempt.unaccounted` records too.

The `started` line exists because the journal cannot report a launch: a
`JournalEntry` carries an outcome, so it is written when the call *resolves*.
It carries the child id so a watcher can begin following that child's own
record immediately.

If the caller cancels a running child, the runner tears down the child, writes
`agent_finished` with `status="cancelled"` and the usage observed so far, then
re-raises cancellation. The sidecar write is protected from cancellation so
cooperative teardown can close the launch bracket. It does not turn a cancelled
call into a journalled outcome. Sidecar writes remain best effort; a process
that is hard-killed cannot guarantee a final event.

## The join

In every journal entry this runner writes, `attempt_id` **is the child id** —
`run7-sr-5`, not an opaque counter. The host knows how it renders a child id,
so it can follow any ledger row to whatever that child wrote. That one field is
the entire link between the workflow view and the per-child view, and it costs
nothing, because the runner had to mint the ordinal anyway.

## Per-call `max_steps`

Not in `child_args`. It rides the request envelope on the child's stdin, where
the [child contract](child-contract.md) already carries it. A template with an
optional flag in it would need conditional groups to express "omit both tokens
when unset"; the envelope needs nothing. An engine that reads `max_steps` only
from argv should learn to read it from the envelope instead.

## Version 2

Version 2 adds `transport`, so a host can launch children that write a result
file instead of streaming events:

```json
{
  "v": 2,
  "transport": "result_file",
  "exe": "/opt/engine",
  "child_args": ["run", "--kind", "{kind}", "--input-format", "json", "--cancel-on-stdin-eof", "--result-file", "{result_file}", "--session", "{child}"],
  "child_id": "run7-sr-{n}",
  "ids": [5, 32]
}
```

A library older than version 2 refuses this handoff: `context()` returns
`None`, so a script behaves as if it had no host rather than passing
`{result_file}` to a child literally. A host that must serve older scripts
keeps writing version 1.
