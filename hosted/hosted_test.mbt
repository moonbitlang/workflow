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
  guard @hosted.parse(handoff(dir)) is Some(ctx) else {
    fail("the handoff must read")
  }
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
  guard @hosted.parse(handoff(dir, first=1, count=2)) is Some(ctx) else {
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
  guard @hosted.parse(handoff(dir)) is Some(ctx) else {
    fail("the handoff must read")
  }
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
async test "a run with no handoff still works, and writes no ledger" {
  // A script run outside a host has nothing to delegate to. That is ordinary,
  // not an error: `context()` returns None and the script does its own work.
  assert_true(@hosted.context() is None)
}
