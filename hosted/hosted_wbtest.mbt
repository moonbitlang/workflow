///|
/// A child speaking the contract: it writes its result to `$2`, echoing the
/// child id it was launched with (`$1`) as the request id and in its report,
/// so a test can prove the reserved child actually reached the process.
let scripted_child : String =
  #|read line
  #|printf 'progress for humans\n'
  #|printf '{"version":1,"request_id":"%s","status":"completed","output":{"answered_by":"%s"},"usage":{"prompt_tokens":11,"completion_tokens":5,"total_tokens":16,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":11},"steps":1}' "$1" "$1" > "$2"

///|
/// A handoff whose engine is `sh` running `child`, with the child id as `$1`
/// and the result path as `$2`.
///
/// WHITE-BOX because a test starts from a DOCUMENT, and the only reader of a
/// document is the private `parse`; a script reaches a `Context` solely
/// through the host's `WORKFLOW_HOST`, which is what `context()` reads.
fn handoff(
  dir : String,
  child? : String = scripted_child,
  first? : Int = 5,
  count? : Int = 4,
) -> Json {
  {
    "v": 2,
    "transport": "result_file",
    "exe": "sh",
    "child_args": ["-c", child, "child", "{child}", "{result_file}"],
    "child_id": "run7-sr-{n}",
    "ids": [first, count],
    "journal": "\{dir}/journal.jsonl",
    "events": "\{dir}/events.jsonl",
  }
}

///|
async test "children are launched into the ids the host reserved" {
  let dir = @fs.tmpdir(prefix="hosted-ids-")
  defer (@fs.rmdir(dir, recursive=true) catch { _ => () })
  let ctx = parse(handoff(dir))
  let answers = ctx.run(wf => {
    @workflow.parallel([
      () => @workflow.attempt(() => wf.agent(prompt="a", kind="explore")),
      () => @workflow.attempt(() => wf.agent(prompt="b", kind="explore")),
    ])
  })
  // Ordinals come from the block, in order, rendered through the host's own
  // template — so the ids the engine saw are ids the host had already set
  // aside, and no other run can be using them.
  let reported = @workflow.collect_ok(answers).map(answer => {
    match answer {
      { "answered_by": String(child), .. } => child
      _ => "?"
    }
  })
  assert_eq(reported, ["run7-sr-5", "run7-sr-6"])
}

///|
async test "the reserved block is the launch ceiling" {
  let dir = @fs.tmpdir(prefix="hosted-block-")
  defer (@fs.rmdir(dir, recursive=true) catch { _ => () })
  let ctx = parse(handoff(dir, first=1, count=2))
  ctx.run(wf => {
    let _ = wf.agent(prompt="one", kind="explore")
    let _ = wf.agent(prompt="two", kind="explore")
    // The third call has no id left. It is REFUSED rather than launched
    // unnamed: a child with no record is what this package exists to prevent,
    // and a script is opaque to its host, so nothing else caps the count.
    let third = @workflow.attempt(() => wf.agent(prompt="three", kind="explore"))
    assert_true(third is Err(_))
  })
}

///|
async test "the ledger names the child, and the sidecar brackets the launch" {
  let dir = @fs.tmpdir(prefix="hosted-ledger-")
  defer (@fs.rmdir(dir, recursive=true) catch { _ => () })
  let ctx = parse(handoff(dir))
  ctx.run(wf => {
    wf.phase("survey")
    let _ = wf.agent(prompt="a", kind="explore", label="scout:a")
  })

  // `attempt_id` is the CHILD ID. That single field is what lets a reader
  // follow a ledger row to whatever that child wrote; a runner minting its own
  // unrelated id would leave the two views with nothing in common.
  let journal = @fs.read_file("\{dir}/journal.jsonl").text()
  assert_true(journal.contains("\"attempt_id\":\"run7-sr-5\""))
  assert_true(journal.contains("\"phase\":\"survey\""))

  // The sidecar reports the launch when it STARTS. The journal cannot: an
  // entry carries an outcome, so a reader with only the ledger learns of a
  // child no earlier than its completion.
  let events = @fs.read_file("\{dir}/events.jsonl").text()
  assert_true(events.contains("\"event\":\"agent_started\""))
  assert_true(events.contains("\"child\":\"run7-sr-5\""))
  assert_true(events.contains("\"label\":\"scout:a\""))
  assert_true(events.contains("\"status\":\"captured\""))
}

///|
async test "cancellation closes the sidecar bracket and still re-raises" {
  let dir = @fs.tmpdir(prefix="hosted-cancel-")
  defer (@fs.rmdir(dir, recursive=true) catch { _ => () })
  // No tool subprocesses: the shell blocks on the open cancellation pipe.
  let ctx = parse(handoff(dir, child="read line; while read line; do :; done"))
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      ctx.run(wf => wf.agent(prompt="q", kind="explore"))
    })
    // Wait for the actual sidecar rather than assuming the runner started
    // within a fixed delay. Only absence means it has not written yet.
    let started = @async.with_timeout_opt(5_000, () => {
      while !@fs.exists("\{dir}/events.jsonl") {
        @async.sleep(10)
      }
      while !@fs.read_file("\{dir}/events.jsonl")
            .text()
            .contains("agent_started") {
        @async.sleep(10)
      }
    })
    assert_true(started is Some(_))
    task.cancel()
    try task.wait() catch {
      error => assert_true(error is @async.WaitedTaskAlreadyCancelled)
    } noraise {
      _ => fail("cancellation must re-raise, not return an outcome")
    }
  }
  let events = @fs.read_file("\{dir}/events.jsonl").text()
  let lines = events.trim().split("\n").collect()
  assert_eq(lines.length(), 2)
  assert_true(lines[0].contains("\"event\":\"agent_started\""))
  assert_true(lines[1].contains("\"event\":\"agent_finished\""))
  assert_true(lines[1].contains("\"child\":\"run7-sr-5\""))
  assert_true(lines[1].contains("\"status\":\"cancelled\""))
  assert_true(lines[1].contains("\"steps\":0"))
  assert_true(lines[1].contains("\"tokens\":0"))
  // The child's spend is in its result, which a cancelled launch never reads.
  assert_true(
    lines[1].contains(
      "\"unaccounted\":\"the launch was cancelled before its result was read\"",
    ),
  )
  let journal = @workflow.Journal::load("\{dir}/journal.jsonl")
  assert_eq(journal.prior().length(), 0)
}

///|
async test "hosted failures retain child identity, usage and sidecar status" {
  let cases : Array[(String, @workflow.AgentFailure, String)] = [
    ("no_report", @workflow.NoReport, "no_report"),
    ("max_steps_exhausted", @workflow.MaxSteps, "max_steps"),
    ("context_yield", @workflow.ContextYield, "context_yield"),
    ("failed", @workflow.Failed("fixture"), "failed"),
  ]
  for (result_status, expected, status) in cases {
    let child = "read line\nprintf '{\"version\":1,\"request_id\":\"%s\",\"status\":\"\{result_status}\",\"reason\":\"fixture\",\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":4,\"total_tokens\":7,\"prompt_cache_hit_tokens\":0,\"prompt_cache_miss_tokens\":3,\"cost_usd\":0.25},\"steps\":2}' \"$1\" > \"$2\""
    let ctx = parse({
      "v": 2,
      "transport": "result_file",
      "exe": "sh",
      "child_args": ["-c", child, "child", "{child}", "{result_file}"],
      "child_id": "test-{n}",
      "ids": [1, 1],
    })
    let events : Array[Json] = []
    let outcome = ctx
      .runner(emit_line=(_, event) => events.push(event))
      .invoke(@workflow.AgentCall(kind="explore", input="q", label="fixture"))
    guard outcome is @workflow.DidNotFinish(failure~, attempt=Some(attempt)) else {
      fail("expected accounted failure")
    }
    assert_true(failure == expected)
    assert_eq(attempt.attempt_id, "test-1")
    assert_eq(attempt.steps_used, 2)
    assert_eq(attempt.prompt_tokens, 3)
    assert_eq(attempt.completion_tokens, 4)
    assert_eq(attempt.cost_usd, Some(0.25))
    assert_eq(events.length(), 2)
    assert_eq(events[1], {
      "event": "agent_finished",
      "child": "test-1",
      "status": status,
      "steps": 2,
      "tokens": 7,
    })
  }
}

///|
async test "a child that leaves no result is failed, and its spend unaccounted" {
  let dir = @fs.tmpdir(prefix="hosted-no-result-")
  defer (@fs.rmdir(dir, recursive=true) catch { _ => () })
  let ctx = parse(handoff(dir, child="read line; exit 3"))
  let events : Array[Json] = []
  let outcome = ctx
    .runner(emit_line=(_, event) => events.push(event))
    .invoke(@workflow.AgentCall(kind="explore", input="q", label="fixture"))
  guard outcome is @workflow.DidNotFinish(failure=Failed(reason), ..) else {
    fail("expected Failed")
  }
  assert_eq(reason, "the child exited 3 without writing a result")
  assert_eq(events[1], {
    "event": "agent_finished",
    "child": "run7-sr-5",
    "status": "failed",
    "steps": 0,
    "tokens": 0,
    "unaccounted": "the child left no result",
  })
}

///|
/// The reason `parse` refuses `document`, or `"read"` when it does not.
fn refusal(document : Json) -> String {
  try parse(document) catch {
    HandoffError(reason) => reason
  } noraise {
    _ => "read"
  }
}

///|
/// A complete handoff with `field` replaced by `value` (or removed, for
/// `None`).
fn with_field(field : String, value : Json?) -> Json {
  let fields : Map[String, Json] = {
    "v": 2,
    "transport": "result_file",
    "exe": "/opt/engine",
    "child_args": ["run", "--kind", "{kind}", "--result-file", "{result_file}"],
    "child_id": "run7-sr-{n}",
    "ids": [5, 32],
  }
  match value {
    Some(value) => fields[field] = value
    None => fields.remove(field)
  }
  Json::object(fields)
}

///|
test "a complete handoff reads; optional coordinates may be blank" {
  let ctx = parse({
    "v": 2,
    "transport": "result_file",
    "exe": "/opt/engine",
    "child_args": [
      "run", "--input-format", "json", "--cancel-on-stdin-eof", "--kind", "{kind}",
      "--result-file", "{result_file}", "--session", "{child}",
    ],
    "child_id": "run7-sr-{n}",
    "ids": [5, 32],
    "journal": "/store/run7-wf-5.jsonl",
    "events": "",
    "cwd": null,
    "deadline_ms": 1000,
  })
  assert_eq(ctx.child_capacity(), 32)
  assert_eq(ctx.journal_path(), Some("/store/run7-wf-5.jsonl"))
  // The sidecar is optional: a host that wants only a ledger names no events
  // file (or a blank one), and the run still accounts for itself.
  assert_eq(ctx.events_path(), None)
  assert_eq(ctx.cwd, None)
  assert_eq(ctx.deadline_ms, Some(1000))
}

///|
test "a handoff this release cannot use is refused with its reason" {
  // Fail closed: each of these would otherwise produce children the host
  // never reserved, or a ledger nothing watches.
  assert_eq(refusal(Json::string("nope")), "not a JSON object")
  assert_eq(refusal(with_field("v", None)), "no handoff version `v`")
  // Version 1 launched children over an event stream this release no longer
  // reads; an unknown version is refused rather than read optimistically.
  assert_eq(
    refusal(with_field("v", Some(1))),
    "unsupported handoff version 1; this release reads version 2",
  )
  assert_eq(
    refusal(with_field("v", Some(3))),
    "unsupported handoff version 3; this release reads version 2",
  )
  assert_eq(refusal(with_field("transport", None)), "no `transport`")
  assert_eq(
    refusal(with_field("transport", Some("stdout_events"))),
    "unsupported transport \"stdout_events\"; this release reads \"result_file\"",
  )
  assert_eq(
    refusal(with_field("exe", Some(""))),
    "`exe` must be a non-empty string",
  )
  assert_eq(
    refusal(with_field("child_args", Some([]))),
    "`child_args` must be a non-empty array of strings",
  )
  assert_eq(
    refusal(with_field("child_args", Some(["run", 1]))),
    "`child_args` must be a non-empty array of strings",
  )
  // A child told nowhere to write its result could never report one.
  assert_eq(
    refusal(with_field("child_args", Some(["run", "--kind", "{kind}"]))),
    "`child_args` must name {result_file}",
  )
  // A child id template that consumes no ordinal names every child alike, and
  // the second child to write its record would land on the first's.
  assert_eq(
    refusal(with_field("child_id", Some("fixed"))),
    "`child_id` must be a string containing {n}",
  )
  // A block of unknown or zero size is not a block.
  let blocks : Array[Json?] = [
    None,
    Some([1, 0]),
    Some([1]),
    Some([1.5, 2]),
    Some([0, 4]),
  ]
  for ids in blocks {
    assert_eq(
      refusal(with_field("ids", ids)),
      "`ids` must be [first, count], both positive integers",
    )
  }
  assert_eq(
    refusal(with_field("journal", Some(5))),
    "`journal` must be a string",
  )
  assert_eq(
    refusal(with_field("deadline_ms", Some(-1))),
    "`deadline_ms` must be a positive integer",
  )
}
