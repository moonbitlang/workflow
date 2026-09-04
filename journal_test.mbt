///|
/// Replay/resume tests. The runners tell the story: `must_not_run` fails
/// the test if a call that should have replayed launches; `recovered`
/// succeeds where a prior generation failed, playing the "resume gets past
/// the failure" role.
async fn must_not_run(_call : @workflow.AgentCall) -> @workflow.AgentOutcome {
  @async.pause()
  fail("this call must have been served from the journal")
}

///|
async fn recovered(call : @workflow.AgentCall) -> @workflow.AgentOutcome {
  @async.pause()
  guard call.input is { "query": String(prompt), .. } else {
    fail("the recovered runner expects the explore-style input")
  }
  Finished(value={ "recovered": prompt }, attempt=attempt_for(call))
}

///|
fn call_for(prompt : String, label? : String) -> @workflow.AgentCall {
  {
    kind: "scout",
    input: { "query": prompt },
    label: label.unwrap_or(prompt),
    max_steps: None,
    scope: "",
    schema: None,
  }
}

///|
fn success_entry(
  prompt : String,
  value : Json,
  label? : String,
) -> @workflow.JournalEntry {
  @workflow.JournalEntry(
    call=call_for(prompt, label?),
    outcome=Finished(value~, attempt=attempt_for(call_for(prompt))),
  )
}

///|
fn failure_entry(
  prompt : String,
  failure : @workflow.AgentFailure,
) -> @workflow.JournalEntry {
  @workflow.JournalEntry(
    call=call_for(prompt),
    outcome=DidNotFinish(failure~, attempt=None),
  )
}

///|
async test "a journalled success replays without launching or charging" {
  let journal = @workflow.Journal::in_memory()
  let wf1 = @workflow.Workflow(runner=@workflow.Runner(scripted), journal~)
  let first = wf1.agent(prompt="hello", kind="scout")
  assert_eq(wf1.calls_made(), 1)
  assert_eq(journal.recorded().length(), 1)
  let events : Array[String] = []
  let wf2 = @workflow.Workflow(
    runner=@workflow.Runner(must_not_run),
    journal=@workflow.Journal::in_memory(prior=journal.recorded()),
    on_event=event => events.push(render(event)),
  )
  let second = wf2.agent(prompt="hello", kind="scout")
  assert_eq(second, first)
  assert_eq(wf2.calls_made(), 0)
  assert_eq(wf2.calls_replayed(), 1)
  assert_eq(wf2.tokens_spent(), 0)
  assert_eq(events, ["replay hello ok"])
}

///|
async test "a journalled failure is re-attempted live" {
  let journal = @workflow.Journal::in_memory()
  let wf1 = @workflow.Workflow(runner=@workflow.Runner(scripted), journal~)
  guard @workflow.attempt(() => wf1.agent(prompt="fail:x", kind="scout"))
    is Err(_) else {
    fail("expected the first attempt to fail")
  }
  guard journal.recorded() is [{ outcome: DidNotFinish(..), .. }] else {
    fail("expected the failure to be journalled losslessly")
  }
  let wf2 = @workflow.Workflow(
    runner=@workflow.Runner(recovered),
    journal=@workflow.Journal::in_memory(prior=journal.recorded()),
  )
  let value = wf2.agent(prompt="fail:x", kind="scout")
  assert_eq(value, { "recovered": "fail:x" })
  assert_eq(wf2.calls_made(), 1)
  assert_eq(wf2.calls_replayed(), 0)
}

///|
async test "a journalled skip replays as the same refusal" {
  let wf = @workflow.Workflow(
    runner=@workflow.Runner(must_not_run),
    journal=@workflow.Journal::in_memory(prior=[
      failure_entry("risky", @workflow.AgentFailure::Skipped),
    ]),
  )
  guard @workflow.attempt(() => wf.agent(prompt="risky", kind="scout"))
    is Err(@workflow.AgentFailed(failure=Skipped, ..)) else {
    fail("expected the recorded refusal to stand")
  }
  assert_eq(wf.calls_replayed(), 1)
  assert_eq(wf.tokens_spent(), 0)
}

///|
async test "replay prefers a newer success over an older failure" {
  let wf = @workflow.Workflow(
    runner=@workflow.Runner(must_not_run),
    journal=@workflow.Journal::in_memory(prior=[
      failure_entry("x", @workflow.AgentFailure::TimedOut),
      success_entry("x", { "answer": 42 }),
    ]),
  )
  assert_eq(wf.agent(prompt="x", kind="scout"), { "answer": 42 })
}

///|
async test "identical calls consume journal entries as a multiset" {
  let wf = @workflow.Workflow(
    runner=@workflow.Runner(recovered),
    journal=@workflow.Journal::in_memory(prior=[
      success_entry("vote", { "sample": 1 }),
      success_entry("vote", { "sample": 2 }),
    ]),
  )
  assert_eq(wf.agent(prompt="vote", kind="scout"), { "sample": 1 })
  assert_eq(wf.agent(prompt="vote", kind="scout"), { "sample": 2 })
  // A third identical call outruns the journal: it runs live.
  assert_eq(wf.agent(prompt="vote", kind="scout"), { "recovered": "vote" })
  assert_eq(wf.calls_replayed(), 2)
  assert_eq(wf.calls_made(), 1)
}

///|
async test "the display label is not part of the work identity" {
  let wf = @workflow.Workflow(
    runner=@workflow.Runner(must_not_run),
    journal=@workflow.Journal::in_memory(prior=[
      success_entry("q", { "a": 1 }, label="scout-one"),
    ]),
  )
  assert_eq(wf.agent(prompt="q", kind="scout", label="scout-two"), { "a": 1 })
}

///|
async test "a file-backed journal resumes across generations" {
  let dir = @fs.tmpdir(prefix="workflow-journal-")
  let path = "\{dir}/journal.jsonl"
  // Generation 1: one success, one failure, appended as they complete.
  let wf1 = @workflow.Workflow(
    runner=@workflow.Runner(scripted),
    journal=@workflow.Journal::load(path),
  )
  let first = wf1.agent(prompt="hello", kind="scout")
  guard @workflow.attempt(() => wf1.agent(prompt="fail:x", kind="scout"))
    is Err(_) else {
    fail("expected the first attempt to fail")
  }
  // Generation 2: the success replays, the failure re-attempts and
  // recovers — and the recovery is appended for the next generation.
  let journal2 = @workflow.Journal::load(path)
  assert_eq(journal2.prior().length(), 2)
  let wf2 = @workflow.Workflow(
    runner=@workflow.Runner(recovered),
    journal=journal2,
  )
  assert_eq(wf2.agent(prompt="hello", kind="scout"), first)
  assert_eq(wf2.agent(prompt="fail:x", kind="scout"), { "recovered": "fail:x" })
  assert_eq(wf2.calls_replayed(), 1)
  assert_eq(wf2.calls_made(), 1)
  // Generation 3: everything replays; nothing may launch.
  let journal3 = @workflow.Journal::load(path)
  assert_eq(journal3.prior().length(), 3)
  let wf3 = @workflow.Workflow(
    runner=@workflow.Runner(must_not_run),
    journal=journal3,
  )
  assert_eq(wf3.agent(prompt="hello", kind="scout"), first)
  assert_eq(wf3.agent(prompt="fail:x", kind="scout"), { "recovered": "fail:x" })
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
}

///|
async test "replay prefers a success over a recorded skip" {
  let wf = @workflow.Workflow(
    runner=@workflow.Runner(must_not_run),
    journal=@workflow.Journal::in_memory(prior=[
      failure_entry("x", @workflow.AgentFailure::Skipped),
      success_entry("x", { "answer": 1 }),
    ]),
  )
  assert_eq(wf.agent(prompt="x", kind="scout"), { "answer": 1 })
}

///|
async test "re-attempting a journalled failure consumes fresh allowance" {
  // Documented semantics: failures never replay, so every generation's
  // re-attempt is a real launch — max_calls must be sized with that in
  // mind. This pins the behavior so changing it is a decision, not drift.
  let wf = @workflow.Workflow(
    runner=@workflow.Runner(recovered),
    journal=@workflow.Journal::in_memory(prior=[
      failure_entry("x", @workflow.AgentFailure::TimedOut),
    ]),
    max_calls=1,
  )
  assert_eq(wf.agent(prompt="x", kind="scout"), { "recovered": "x" })
  guard @workflow.attempt(() => wf.agent(prompt="y", kind="scout"))
    is Err(@workflow.CallBudgetExhausted(..)) else {
    fail("expected the re-attempt to have spent the allowance")
  }
}

///|
async test "concurrent identical calls consume distinct journal entries" {
  let wf = @workflow.Workflow(
    runner=@workflow.Runner(must_not_run),
    journal=@workflow.Journal::in_memory(prior=[
      success_entry("vote", { "sample": 1 }),
      success_entry("vote", { "sample": 2 }),
    ]),
  )
  let results = @workflow.parallel([
    () => @workflow.attempt(() => wf.agent(prompt="vote", kind="scout")),
    () => @workflow.attempt(() => wf.agent(prompt="vote", kind="scout")),
  ])
  let values = @workflow.all_ok(results)
  // Completion order is scheduling-dependent; the multiset is not.
  assert_true(values.contains({ "sample": 1 }))
  assert_true(values.contains({ "sample": 2 }))
  assert_eq(wf.calls_replayed(), 2)
}

///|
async test "concurrent live agents append whole lines" {
  let dir = @fs.tmpdir(prefix="workflow-journal-parallel-")
  let path = "\{dir}/journal.jsonl"
  let wf = @workflow.Workflow(
    runner=@workflow.Runner(scripted),
    journal=@workflow.Journal::load(path),
  )
  let results = @workflow.parallel([
    () => @workflow.attempt(() => wf.agent(prompt="a", kind="scout")),
    () => @workflow.attempt(() => wf.agent(prompt="b", kind="scout")),
    () => @workflow.attempt(() => wf.agent(prompt="c", kind="scout")),
  ])
  assert_eq(@workflow.all_ok(results).length(), 3)
  // Every line survives a reload: no interleaved bytes, no torn entries.
  assert_eq(@workflow.Journal::load(path).prior().length(), 3)
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
}

///|
async test "label-only differences replay through a file round trip" {
  let dir = @fs.tmpdir(prefix="workflow-journal-label-")
  let path = "\{dir}/journal.jsonl"
  let wf1 = @workflow.Workflow(
    runner=@workflow.Runner(scripted),
    journal=@workflow.Journal::load(path),
  )
  let first = wf1.agent(prompt="q", kind="scout", label="scout-one")
  let wf2 = @workflow.Workflow(
    runner=@workflow.Runner(must_not_run),
    journal=@workflow.Journal::load(path),
  )
  assert_eq(wf2.agent(prompt="q", kind="scout", label="scout-two"), first)
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
}

///|
async test "a failed journal append surfaces as one errored bracket" {
  let dir = @fs.tmpdir(prefix="workflow-journal-gone-")
  let path = "\{dir}/journal.jsonl"
  let journal = @workflow.Journal::load(path)
  // Yank the directory out from under the journal: the outcome resolves,
  // then persistence fails.
  @fs.rmdir(dir, recursive=true)
  let events : Array[String] = []
  let wf = @workflow.Workflow(runner=@workflow.Runner(scripted), journal~, on_event=event => {
    events.push(render(event))
  })
  let mut raised = false
  let _ = wf.agent(prompt="q", kind="scout") catch {
    _ => {
      raised = true
      Json::null()
    }
  }
  assert_true(raised)
  // Exactly one bracket close, as infrastructure failure — and the
  // attempt's tokens were charged before persistence was tried.
  assert_eq(events, ["start q scout -", "finish q errored"])
  assert_eq(wf.tokens_spent(), 10)
}

///|
async test "a torn final line is dropped AND repaired on disk" {
  let dir = @fs.tmpdir(prefix="workflow-journal-torn-")
  let entry_line = (
      { "v": 1, "e": Json(success_entry("hello", { "a": 1 })) } : Json).stringify() +
    "\n"
  // Torn tail: the signature of a crash mid-append.
  let torn = "\{dir}/torn.jsonl"
  @fs.write_file(torn, entry_line + "{\"call\": {\"kind")
  let journal = @workflow.Journal::load(torn)
  assert_eq(journal.prior().length(), 1)
  // The load repaired the physical tail: a new append must land on a
  // clean line boundary, and the next generation must see both entries —
  // the regression for append-after-torn-tail corrupting the file.
  let wf = @workflow.Workflow(runner=@workflow.Runner(scripted), journal~)
  let _ = wf.agent(prompt="world", kind="scout")
  assert_eq(@workflow.Journal::load(torn).prior().length(), 2)
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
}

///|
async test "a valid final line missing its newline is kept and normalized" {
  let dir = @fs.tmpdir(prefix="workflow-journal-noeol-")
  let entry_line = (
      { "v": 1, "e": Json(success_entry("hello", { "a": 1 })) } : Json).stringify() +
    "\n"
  let unterminated = (
    { "v": 1, "e": Json(success_entry("tail", { "b": 2 })) } : Json).stringify()
  let path = "\{dir}/journal.jsonl"
  @fs.write_file(path, entry_line + unterminated)
  let journal = @workflow.Journal::load(path)
  assert_eq(journal.prior().length(), 2)
  // Repair added the missing newline: an append cannot fuse two entries.
  let wf = @workflow.Workflow(runner=@workflow.Runner(scripted), journal~)
  let _ = wf.agent(prompt="world", kind="scout")
  assert_eq(@workflow.Journal::load(path).prior().length(), 3)
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
}

///|
async test "a tail torn mid-codepoint cannot poison the healthy prefix" {
  let dir = @fs.tmpdir(prefix="workflow-journal-codepoint-")
  let entry_line = (
      { "v": 1, "e": Json(success_entry("hello", { "a": 1 })) } : Json).stringify() +
    "\n"
  let path = "\{dir}/journal.jsonl"
  @fs.write_file(path, entry_line + "{\"call\": \"")
  // One leading byte of a two-byte UTF-8 sequence: strict whole-file
  // decoding would refuse the entire journal.
  @fs.write_file(path, b"\xc3", append=true, create_mode=OpenOrCreate)
  let journal = @workflow.Journal::load(path)
  assert_eq(journal.prior().length(), 1)
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
}

///|
async test "corruption before the final line raises JournalCorrupted" {
  let dir = @fs.tmpdir(prefix="workflow-journal-corrupt-")
  let entry_line = (
      { "v": 1, "e": Json(success_entry("hello", { "a": 1 })) } : Json).stringify() +
    "\n"
  let corrupt = "\{dir}/corrupt.jsonl"
  @fs.write_file(corrupt, entry_line + "{\"call\": {\"kind\n" + entry_line)
  let mut raised = false
  let _ = @workflow.Journal::load(corrupt) catch {
    @workflow.JournalCorrupted(line=2, ..) => {
      raised = true
      @workflow.Journal::in_memory()
    }
    _ => fail("expected JournalCorrupted at line 2")
  }
  assert_true(raised)
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
}

///|
async test "a vetoed replay runs live and the stale entry stays consumed" {
  let vetoes : Ref[Int] = { val: 0, }
  let wf = @workflow.Workflow(
    runner=@workflow.Runner(recovered, validate_replay=(_, _) => {
      vetoes.val += 1
      Rerun
    }),
    journal=@workflow.Journal::in_memory(prior=[
      success_entry("x", { "stale": true }),
    ]),
  )
  // The journal has a hit, but the engine vetoes it: live run.
  assert_eq(wf.agent(prompt="x", kind="scout"), { "recovered": "x" })
  assert_eq(wf.calls_replayed(), 0)
  assert_eq(wf.calls_made(), 1)
  assert_eq(vetoes.val, 1)
  // The vetoed entry was consumed: the next identical call never even
  // reaches the validator.
  assert_eq(wf.agent(prompt="x", kind="scout"), { "recovered": "x" })
  assert_eq(vetoes.val, 1)
}

///|
async test "a stale candidate does not mask the newer valid one" {
  // Two journalled successes for the same call; the engine's validator
  // rejects the first (stale) and accepts the second — replay must WALK
  // to the valid candidate, not fall back to a live run.
  let wf = @workflow.Workflow(
    runner=@workflow.Runner(recovered, validate_replay=(_, outcome) => {
      if outcome is Finished(value={ "sample": 2, .. }, ..) {
        Serve(outcome)
      } else {
        Rerun
      }
    }),
    journal=@workflow.Journal::in_memory(prior=[
      success_entry("x", { "sample": 1 }),
      success_entry("x", { "sample": 2 }),
    ]),
  )
  assert_eq(wf.agent(prompt="x", kind="scout"), { "sample": 2 })
  assert_eq(wf.calls_replayed(), 1)
  assert_eq(wf.calls_made(), 0)
  // Both candidates are now consumed (one vetoed, one served): the next
  // identical call runs live.
  assert_eq(wf.agent(prompt="x", kind="scout"), { "recovered": "x" })
  assert_eq(wf.calls_made(), 1)
}

///|
async test "a validator unwind rolls the claim back" {
  let attempts : Ref[Int] = { val: 0, }
  let wf = @workflow.Workflow(
    runner=@workflow.Runner(must_not_run, validate_replay=(_, outcome) => {
      attempts.val += 1
      if attempts.val == 1 {
        // The registry check blew up mid-validation: the claim must be
        // rolled back, not burned.
        fail("registry unavailable")
      }
      Serve(outcome)
    }),
    journal=@workflow.Journal::in_memory(prior=[
      success_entry("x", { "answer": 42 }),
    ]),
  )
  let mut unwound = false
  let _ = wf.agent(prompt="x", kind="scout") catch {
    _ => {
      unwound = true
      Json::null()
    }
  }
  assert_true(unwound)
  // Same entry, second chance: validation now passes and the entry is
  // still there to serve.
  assert_eq(wf.agent(prompt="x", kind="scout"), { "answer": 42 })
  assert_eq(wf.calls_replayed(), 1)
}

///|
async test "an entry records its phase and wall-clock window; replay ignores both" {
  let journal = @workflow.Journal::in_memory()
  let wf1 = @workflow.Workflow(runner=@workflow.Runner(scripted), journal~)
  wf1.phase("Scan")
  let _ = wf1.agent(prompt="q", kind="scout")
  guard journal.recorded() is [entry] else { fail("expected one entry") }
  assert_eq(entry.phase, Some("Scan"))
  guard entry.started_at is Some(started) && entry.finished_at is Some(finished) else {
    fail("expected the wall-clock window on a live entry")
  }
  // Milliseconds, not seconds: later than 2023, and the window is ordered.
  assert_true(started > 1_700_000_000_000)
  assert_true(finished >= started)
  // Attribution is not identity: the next generation replays the call
  // under a different phase.
  let wf2 = @workflow.Workflow(
    runner=@workflow.Runner(must_not_run),
    journal=@workflow.Journal::in_memory(prior=journal.recorded()),
  )
  wf2.phase("Verify")
  let _ = wf2.agent(prompt="q", kind="scout")
  assert_eq(wf2.calls_replayed(), 1)
}

///|
test "the entry's JSON shape: attribution only when known, timestamps as numbers" {
  let bare = success_entry("q", { "a": 1 })
  let text = Json(bare).stringify()
  assert_false(text.contains("\"phase\""))
  assert_false(text.contains("started_at"))
  assert_false(text.contains("finished_at"))
  let full = @workflow.JournalEntry(
    call=bare.call,
    outcome=bare.outcome,
    phase="Scan",
    started_at=1_700_000_000_000,
    finished_at=1_700_000_000_250,
  )
  let text = Json(full).stringify()
  assert_true(text.contains("\"phase\":\"Scan\""))
  assert_true(text.contains("\"started_at\":1700000000000"))
  assert_true(text.contains("\"finished_at\":1700000000250"))
  for entry in [bare, full] {
    let back : @workflow.JournalEntry = @json.from_json(Json(entry))
    assert_true(back == entry)
  }
}

///|
test "a mistyped attribution field is a malformed entry, not a missing one" {
  let entry = success_entry("q", { "a": 1 })
  for
    bad in [
      ({ "phase": 7 } : Json),
      { "started_at": "soon" },
      { "finished_at": 1.5 },
    ] {
    let json = Json(entry)
    guard json is Object(fields) && bad is Object(extra) else {
      fail("objects expected")
    }
    for key, value in extra {
      fields[key] = value
    }
    let decoded : Result[@workflow.JournalEntry, Error] = Ok(
      @json.from_json(json),
    ) catch {
      error => Err(error)
    }
    assert_true(decoded is Err(_))
  }
  // `null` reads as absent.
  let json = Json(entry)
  guard json is Object(fields) else { fail("object expected") }
  fields["phase"] = Json::null()
  fields["started_at"] = Json::null()
  let back : @workflow.JournalEntry = @json.from_json(json)
  assert_true(back == entry)
}

///|
async test "a pre-attribution journal line loads unchanged and still replays" {
  let dir = @fs.tmpdir(prefix="workflow-journal-legacy-")
  let path = "\{dir}/journal.jsonl"
  // The 0.4 line shape: the call and the outcome alone.
  let legacy =
    #|{"v":1,"e":{"call":{"kind":"scout","input":{"query":"hello"},"label":"hello","scope":""},"outcome":["Finished",{"value":{"a":1},"attempt":{"attempt_id":"sr-hello","steps_used":1,"prompt_tokens":7,"completion_tokens":3}}]}}
  @fs.write_file(path, legacy + "\n")
  let journal = @workflow.Journal::load(path)
  guard journal.prior() is [entry] else { fail("expected the legacy entry") }
  assert_eq(entry.phase, None)
  assert_eq(entry.started_at, None)
  assert_eq(entry.finished_at, None)
  assert_true(entry == success_entry("hello", { "a": 1 }))
  let wf = @workflow.Workflow(runner=@workflow.Runner(must_not_run), journal~)
  assert_eq(wf.agent(prompt="hello", kind="scout"), { "a": 1 })
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
}

///|
async test "a metadata line is skipped by replay and preserved by repair" {
  let dir = @fs.tmpdir(prefix="workflow-journal-meta-")
  let path = "\{dir}/journal.jsonl"
  let meta = "{\"v\":1,\"plan\":{\"stages\":[\"scan\"]}}\n"
  let entry_line = (
      { "v": 1, "e": Json(success_entry("hello", { "a": 1 })) } : Json).stringify() +
    "\n"
  // Metadata, an entry, a blank line, then a torn tail.
  @fs.write_file(path, meta + entry_line + "\n{\"v\":1,\"e\":{\"call")
  let journal = @workflow.Journal::load(path)
  assert_eq(journal.prior().length(), 1)
  // Repair truncated the tail and kept every healthy byte, metadata
  // and blank line included, rather than re-encoding what it understood.
  assert_eq(@fs.read_file(path).text(), meta + entry_line + "\n")
  // The next generation appends after it and reads both entries.
  let wf = @workflow.Workflow(runner=@workflow.Runner(scripted), journal~)
  let _ = wf.agent(prompt="world", kind="scout")
  assert_eq(@workflow.Journal::load(path).prior().length(), 2)
  assert_true(@fs.read_file(path).text().has_prefix(meta + entry_line))
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
}
