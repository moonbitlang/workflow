///|
/// A child speaking the contract: one accounted usage line, then the report.
/// It echoes back the id it was launched with, so a test can prove the
/// reserved child actually reached the process.
let scripted_child : String =
  #|read line
  #|printf '{"event":"usage","usage":{"prompt_tokens":11,"completion_tokens":5,"total_tokens":16,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":11}}\n'
  #|printf '{"subrun_report": {"answered_by": "'"$1"'"}}\n'

///|
/// A handoff whose engine is `sh` running the scripted child, with the child
/// id passed as `$1` so it comes back in the report.
///
/// WHITE-BOX because a test starts from a DOCUMENT, and the only reader of a
/// document is the private `parse`; a script reaches a `Context` solely
/// through the host's `WORKFLOW_HOST`, which is what `context()` reads.
fn handoff(dir : String, first? : Int = 5, count? : Int = 4) -> Json {
  {
    "v": 1,
    "exe": "sh",
    "child_args": ["-c", scripted_child, "child", "{child}", "{kind}"],
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
  guard parse(handoff(dir)) is Some(ctx) else { fail("the handoff must read") }
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
  guard parse(handoff(dir, first=1, count=2)) is Some(ctx) else {
    fail("the handoff must read")
  }
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
  guard parse(handoff(dir)) is Some(ctx) else { fail("the handoff must read") }
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
  let document = handoff(dir)
  guard document is Object(fields) else { fail("expected an object") }
  // No tool subprocesses: the shell blocks on the open cancellation pipe.
  fields["child_args"] = ["-c", "read line; while read line; do :; done"]
  guard parse(document) is Some(ctx) else { fail("the handoff must read") }
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
  let journal = @workflow.Journal::load("\{dir}/journal.jsonl")
  assert_eq(journal.prior().length(), 0)
}

///|
async test "hosted failures retain child identity, usage and sidecar status" {
  let cases : Array[(String, @workflow.AgentFailure, String)] = [
    ("", @workflow.NoReport, "no_report"),
    ("{\"event\":\"max_steps_exhausted\"}", @workflow.MaxSteps, "max_steps"),
    (
      "{\"event\":\"context_yield\",\"to_sequence\":1,\"answer\":\"later\"}",
      @workflow.ContextYield,
      "context_yield",
    ),
    (
      "{\"event\":\"turn_failed\",\"error\":\"fixture\"}",
      @workflow.Failed("fixture"),
      "failed",
    ),
  ]
  for (terminal, expected, status) in cases {
    let child = "read line\nprintf '%s\\n' '{\"event\":\"agent_step\",\"step\":2}' '{\"event\":\"usage\",\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":4,\"total_tokens\":7,\"prompt_cache_hit_tokens\":0,\"prompt_cache_miss_tokens\":3,\"cost_usd\":0.25}}' '\{terminal}'"
    guard parse({
        "v": 1,
        "exe": "sh",
        "child_args": ["-c", child],
        "child_id": "test-{n}",
        "ids": [1, 1],
      })
      is Some(ctx) else {
      fail("expected context")
    }
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
/// A transport-2 child: it writes its result, echoing the child id it was
/// launched with (`$1`) as the request id and in its report, to `$2`.
let result_file_child : String =
  #|read line
  #|printf 'progress for humans\n'
  #|printf '{"version":1,"request_id":"%s","status":"completed","output":{"answered_by":"%s"},"usage":{"prompt_tokens":11,"completion_tokens":5,"total_tokens":16,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":11},"steps":1}' "$1" "$1" > "$2"

///|
fn result_file_handoff(dir : String, child : String) -> Json {
  {
    "v": 2,
    "transport": "result_file",
    "exe": "sh",
    "child_args": ["-c", child, "child", "{child}", "{result_file}"],
    "child_id": "run7-sr-{n}",
    "ids": [5, 4],
    "journal": "\{dir}/journal.jsonl",
    "events": "\{dir}/events.jsonl",
  }
}

///|
async test "a version 2 handoff launches result-file children" {
  let dir = @fs.tmpdir(prefix="hosted-result-file-")
  defer (@fs.rmdir(dir, recursive=true) catch { _ => () })
  guard parse(result_file_handoff(dir, result_file_child)) is Some(ctx) else {
    fail("the handoff must read")
  }
  let answer = ctx.run(wf => wf.agent(prompt="a", kind="explore"))
  assert_eq(answer, { "answered_by": "run7-sr-5" })
  let events = @fs.read_file("\{dir}/events.jsonl").text()
  assert_true(events.contains("\"status\":\"captured\""))
  assert_true(events.contains("\"tokens\":16"))
  assert_false(events.contains("unaccounted"))
}

///|
async test "a cancelled result-file launch says its spend is unaccounted" {
  let dir = @fs.tmpdir(prefix="hosted-result-file-cancel-")
  defer (@fs.rmdir(dir, recursive=true) catch { _ => () })
  guard parse(
      result_file_handoff(dir, "read line; while read line; do :; done"),
    )
    is Some(ctx) else {
    fail("the handoff must read")
  }
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      ctx.run(wf => wf.agent(prompt="q", kind="explore"))
    })
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
  assert_true(events.contains("\"status\":\"cancelled\""))
  assert_true(
    events.contains(
      "\"unaccounted\":\"the launch was cancelled before its result was read\"",
    ),
  )
}
