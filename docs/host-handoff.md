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
children the host never reserved.

An unset or blank variable means no handoff: `@hosted.context()` returns
`None`, and a script may do its own work. A handoff that IS set is read
whole or not at all — the reader **fails closed**: any missing or malformed
required field, or a `v` or `transport` it does not read, raises
`HandoffError` with the reason rather than yielding a partial context, and
never reads as "no handoff" (a script that fell back to standalone work on a
broken handoff would launch children its host never reserved and cannot
see).

```json
{
  "v": 2,
  "transport": "result_file",
  "exe": "/opt/engine",
  "child_args": ["run", "--input-format", "json", "--cancel-on-stdin-eof", "--kind", "{kind}", "--result-file", "{result_file}", "--session", "{child}", "--session-root", "/store"],
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
| `v` | yes | The handoff document's version: `2`. Anything else is refused. |
| `transport` | yes | `"result_file"`: each child writes one result file ([child contract](child-contract.md)). Anything else is refused. |
| `exe` | yes | The engine to spawn. An absolute path is strongly advised: a sandbox policy that admits programs by exact path then admits *this* binary and not a same-named one earlier in `PATH`. |
| `child_args` | yes | The argv for one child, as a non-empty array of strings. `{kind}` is replaced by the call's kind and `{child}` by the rendered child id, in every token. It must also name `{result_file}`, which the runner replaces with a fresh private path per launch; a template that does not is refused. |
| `child_id` | yes | How this host names a child. Must contain `{n}`, which is replaced by the child's ordinal; a template that consumed no ordinal would name every child alike. |
| `ids` | yes | `[first, count]`, both positive integers: the ordinals this script may use. It is also the **launch ceiling** — see below. |
| `journal` | no | Where to append the ledger of resolved calls. Absent, null, or empty means an in-memory journal that dies with the process. |
| `events` | no | Where to append the sidecar of launch brackets. Absent, null, or empty means no sidecar. |
| `cwd` | no | The child's working directory. Absent, null, or empty means the script's own. |
| `deadline_ms` | no | Wall deadline per child, a positive integer. Default 600 000. |

## Host-specific extensions

Hosts may add namespaced top-level fields, for example
`"openseek": {"audit": {"goal": "ship the parser"}}`. `ctx.extension("openseek")`
returns that value as `Json?`; the host and its scripts own its schema and
validation. The library preserves arbitrary JSON values without interpreting
them. Missing fields return `None`; explicit `null` returns `Some(Null)`.
Reserved fields in the table above are not extensions and are never returned
by this accessor. Hosts should use their own namespace to avoid collisions
with future common fields. Adding an extension needs no new `v`.

Three version numbers are in play, and none of them moves with another:
`v` is the handoff document's (`2`); the request and result documents a
child reads and writes are version `1` (the
[child contract](child-contract.md)); and the `moonbitlang/workflow` package
has its own release version.

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
to and should do its own work. A variable that is set but unusable raises
`HandoffError`; let it escape `main`, which prints
`unusable WORKFLOW_HOST handoff: <reason>` and exits nonzero.

`ctx.run(wf => ...)` yields a `Workflow` whose `Runner` spawns `exe` with the
substituted argv, journals to `journal`, and writes two sidecar lines per
launch:

```json
{"event":"agent_started","child":"run7-sr-5","kind":"explore","label":"scout:x"}
{"event":"agent_finished","child":"run7-sr-5","status":"captured","steps":12,"tokens":3400}
```

When the runner could not get the child's own account of its spend (a child
that died without a result, say), the finish line carries
`"unaccounted": "<why>"` and the counters are zero, as the journal's
`AgentAttempt.unaccounted` records too.

The `started` line exists because the journal cannot report a launch: a
`JournalEntry` carries an outcome, so it is written when the call *resolves*.
It carries the child id so a watcher can begin following that child's own
record immediately.

If the caller cancels a running child, the runner tears down the child, writes
`agent_finished` with `status="cancelled"`, zero counters, and an
`unaccounted` reason (the child's spend is in a result nobody read), then
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

Not in `child_args`. It rides the request on the child's stdin
(`limits.max_steps`), where the [child contract](child-contract.md) already
carries it. A template with an optional flag in it would need conditional
groups to express "omit both tokens when unset"; the request needs nothing.
An engine that reads `max_steps` only from argv should learn to read it from
the request instead.

## Versions

Version 2 is the only handoff this release reads. Version 1 launched
children that streamed events on stdout, a transport this package no longer
has; a version 1 handoff raises `HandoffError`. A library older than version
2 refuses a version 2 handoff (to it, `context()` is `None`), so a script
pinned to such a release behaves as if it had no host rather than passing
`{result_file}` to a child literally.
