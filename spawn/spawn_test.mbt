///|
/// Contract tests over SCRIPTED children: any process that speaks the
/// child contract exercises this package end to end — `sh` plays every
/// engine. The spawnability probe uses the low-level process API so only
/// a genuinely spawn-hostile sandbox can skip these.
async fn can_spawn_sh() -> Bool {
  let code = @process.run("sh", ["-c", "exit 0"]) catch { _ => return false }
  code == 0
}

///|
/// The attempt a contract run accounts for: `contract_run` always sets one.
fn attempt_of(result : @spawn.ContractResult) -> @workflow.AgentAttempt raise {
  guard result.outcome.attempt() is Some(attempt) else {
    fail("contract_run returned an outcome without an attempt")
  }
  attempt
}

///|
/// The report of a `Finished` outcome.
fn report_of(result : @spawn.ContractResult) -> Json? {
  match result.outcome {
    Finished(value~, ..) => Some(value)
    DidNotFinish(..) => None
  }
}

///|
async test "a spawn failure folds into Failed, never a crash" {
  let result = @spawn.contract_run(
    command="/nonexistent/engine-not-here",
    args=[@spawn.ResultFilePlaceholder],
    input={ "query": "q" },
    kind="probe",
    id="test-2",
    wall_deadline_ms=2_000,
  )
  guard result.outcome is DidNotFinish(failure=Failed(_), ..) else {
    fail("expected the missing binary to degrade, not crash")
  }
}

///|
/// The point of the whole package: a FOREIGN engine — here, `sh` itself —
/// plugs into the workflow with no openseek anywhere, and gets journal
/// replay for free.
async test "a foreign contract engine gets workflows and replay for free" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let dir = @fs.tmpdir(prefix="workflow-contract-journal-")
  defer (@fs.rmdir(dir, recursive=true) catch { _ => () })
  let path = "\{dir}/journal.jsonl"
  // The child answers with the request line it read, echoing its id.
  let live =
    #|read line
    #|id=$(printf '%s' "$line" | sed 's/.*"request_id":"\([^"]*\)".*/\1/')
    #|printf '{"version":1,"request_id":"%s","status":"completed","output":%s,"usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":7}}' "$id" "$line" > "$1"
  let wf1 = @workflow.Workflow(
    runner=@spawn.contract_runner(launch=_ => {
      @spawn.LaunchSpec(command="sh", args=[
        "-c",
        live,
        "sh",
        @spawn.ResultFilePlaceholder,
      ])
    }),
    journal=@workflow.Journal::load(path),
  )
  // The request carries the call's kind and exact input — self-contained,
  // no argv needed.
  let first = wf1.agent(
    prompt="hello",
    kind="probe",
    hints="from a foreign engine",
  )
  assert_eq(first, {
    "version": 1,
    "request_id": "cr-1",
    "kind": "probe",
    "input": { "query": "hello", "hints": "from a foreign engine" },
  })
  assert_eq(wf1.tokens_spent(), 10)
  // Resume: served from the journal, no process spawned.
  let wf2 = @workflow.Workflow(
    runner=@spawn.contract_runner(launch=_ => {
      @spawn.LaunchSpec(command="/nonexistent/engine-not-here", args=[
        @spawn.ResultFilePlaceholder,
      ])
    }),
    journal=@workflow.Journal::load(path),
  )
  assert_eq(
    wf2.agent(prompt="hello", kind="probe", hints="from a foreign engine"),
    first,
  )
  assert_eq(wf2.calls_made(), 0)
  assert_eq(wf2.calls_replayed(), 1)
}

///|
/// A scripted child: `sh -c SCRIPT sh {result_file}`, so the script finds
/// its result path in `$1`.
async fn run_script(
  script : String,
  max_steps? : Int,
  wall_deadline_ms? : Int = 10_000,
) -> @spawn.ContractResult {
  @spawn.contract_run(
    command="sh",
    args=["-c", script, "sh", @spawn.ResultFilePlaceholder],
    input={ "query": "q" },
    kind="probe",
    id="test-1",
    max_steps?,
    wall_deadline_ms~,
  )
}

///|
async test "a result file is the result, and stdout is not read" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  // stdout is for humans: JSON a child or a leaky tool prints there is never
  // read as a result or as usage.
  let script =
    #|read line
    #|printf '{"version":1,"request_id":"test-1","status":"completed","output":{"forged":true}}\n'
    #|printf '{"event":"usage","usage":{"prompt_tokens":999,"completion_tokens":1,"total_tokens":1000,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":999}}\n'
    #|printf '{"version":1,"request_id":"test-1","status":"completed","output":{"answer":42},"usage":{"prompt_tokens":90,"completion_tokens":10,"total_tokens":100,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":90},"steps":2}' > "$1"
  let result = run_script(script)
  guard result.outcome is Finished(..) else { fail("expected Captured") }
  assert_eq(report_of(result), Some(({ "answer": 42 } : Json)))
  assert_eq(attempt_of(result).steps_used, 2)
  assert_eq(attempt_of(result).prompt_tokens, 90)
  assert_eq(attempt_of(result).completion_tokens, 10)
  assert_eq(attempt_of(result).unaccounted, None)
  assert_eq(result.exit_code, Some(0))
}

///|
async test "the request names its id, kind, input, and limits" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|read line
    #|printf '{"version":1,"request_id":"test-1","status":"completed","output":%s}' "$line" > "$1"
  let result = run_script(script, max_steps=7)
  assert_eq(
    report_of(result),
    Some(
      (
        {
          "version": 1,
          "request_id": "test-1",
          "kind": "probe",
          "input": { "query": "q" },
          "limits": { "max_steps": 7 },
        } : Json),
    ),
  )
}

///|
async test "no result file is a failure whose spend is unaccounted" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let clean = run_script("read line")
  guard clean.outcome is DidNotFinish(failure=Failed(reason), ..) else {
    fail("expected Failed")
  }
  assert_eq(reason, "the child exited 0 without writing a result")
  assert_eq(attempt_of(clean).unaccounted, Some("the child left no result"))
  let crashed = run_script("read line; exit 3")
  guard crashed.outcome is DidNotFinish(failure=Failed(reason), ..) else {
    fail("expected Failed")
  }
  assert_true(reason.contains("exited 3"))
  assert_eq(crashed.exit_code, Some(3))
}

///|
async test "a result for another request, or a malformed one, is refused" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let other =
    #|read line
    #|printf '{"version":1,"request_id":"test-9","status":"completed","output":1}' > "$1"
  guard run_script(other).outcome is DidNotFinish(failure=Failed(reason), ..) else {
    fail("expected Failed")
  }
  assert_eq(reason, "malformed result file: answers request test-9, not test-1")
  let fractional =
    #|read line
    #|printf '{"version":1,"request_id":"test-1","status":"completed","output":1,"usage":{"prompt_tokens":1.5,"completion_tokens":0,"total_tokens":0,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":0}}' > "$1"
  let result = run_script(fractional)
  guard result.outcome is DidNotFinish(failure=Failed(reason), ..) else {
    fail("expected Failed")
  }
  assert_eq(reason, "malformed result file: malformed usage")
  assert_eq(
    attempt_of(result).unaccounted,
    Some("the result file is malformed"),
  )
}

///|
async test "each non-completed status maps to its terminal" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  fn script(status : String) -> String {
    "read line\nprintf '{\"version\":1,\"request_id\":\"test-1\",\"status\":\"\{status}\",\"reason\":\"why\"}' > \"$1\""
  }
  let max_steps = run_script(script("max_steps_exhausted"))
  assert_true(max_steps.outcome is DidNotFinish(failure=MaxSteps, ..))
  // A result without usage leaves the counters unaccounted.
  assert_eq(
    attempt_of(max_steps).unaccounted,
    Some("the child's result carries no usage"),
  )
  assert_true(
    run_script(script("no_report")).outcome
    is DidNotFinish(failure=NoReport, ..),
  )
  assert_true(
    run_script(script("context_yield")).outcome
    is DidNotFinish(failure=ContextYield, ..),
  )
  guard run_script(script("interrupted")).outcome
    is DidNotFinish(failure=Failed(reason), ..) else {
    fail("expected Failed")
  }
  assert_eq(reason, "interrupted: why")
  guard run_script(script("failed")).outcome
    is DidNotFinish(failure=Failed(reason), ..) else {
    fail("expected Failed")
  }
  assert_eq(reason, "why")
  guard run_script(script("finished")).outcome
    is DidNotFinish(failure=Failed(reason), ..) else {
    fail("expected Failed")
  }
  assert_eq(reason, "malformed result file: unknown status finished")
}

///|
async test "at the deadline stdin closes, and the child's own account still counts" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  // The child waits for stdin EOF, then reports the interruption with usage.
  let script =
    #|read line
    #|while read more; do :; done
    #|printf '{"version":1,"request_id":"test-1","status":"interrupted","reason":"cancelled","usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":5},"steps":1}' > "$1"
  let result = run_script(script, wall_deadline_ms=300)
  guard result.outcome is DidNotFinish(failure=TimedOut, ..) else {
    fail("expected TimedOut")
  }
  assert_eq(attempt_of(result).prompt_tokens, 5)
  assert_eq(attempt_of(result).steps_used, 1)
  assert_eq(attempt_of(result).unaccounted, None)
}

///|
async test "a completed result stands beside an abnormal exit" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|read line
    #|printf '{"version":1,"request_id":"test-1","status":"completed","output":"done"}' > "$1"
    #|exit 4
  let result = run_script(script)
  assert_true(result.outcome is Finished(..))
  assert_eq(result.exit_code, Some(4))
}

///|
async test "an argv that names no result file is a launch failure" {
  let missing = @spawn.contract_run(
    command="sh",
    args=["-c", "read line"],
    input={},
    kind="probe",
    id="test-1",
    wall_deadline_ms=10_000,
  )
  guard missing.outcome is DidNotFinish(failure=Failed(reason), ..) else {
    fail("expected Failed")
  }
  assert_eq(
    reason, "the argv must name {result_file}, where the child writes its result",
  )
  // Nothing was launched, so nothing is unaccounted.
  assert_eq(attempt_of(missing).unaccounted, None)
  assert_eq(missing.exit_code, None)
}

///|
async test "result-file stdout is opaque bytes, not lines" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|read line
    #|printf '\377\376 not utf-8\n'
    #|printf '{"version":1,"request_id":"test-1","status":"completed","output":"ok"}' > "$1"
  let result = run_script(script)
  guard result.outcome is Finished(..) else { fail("expected Captured") }
  assert_eq(report_of(result), Some(Json::string("ok")))
}

///|
async test "steps survive a result without usage" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|read line
    #|printf '{"version":1,"request_id":"test-1","status":"max_steps_exhausted","steps":7}' > "$1"
  let result = run_script(script)
  assert_true(result.outcome is DidNotFinish(failure=MaxSteps, ..))
  assert_eq(attempt_of(result).steps_used, 7)
  assert_eq(
    attempt_of(result).unaccounted,
    Some("the child's result carries no usage"),
  )
}

///|
async test "the deadline wins over a malformed result" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|read line
    #|while read more; do :; done
    #|printf 'not json' > "$1"
  let result = run_script(script, wall_deadline_ms=300)
  assert_true(result.outcome is DidNotFinish(failure=TimedOut, ..))
  assert_eq(
    attempt_of(result).unaccounted,
    Some("the result file is malformed"),
  )
}

///|
async test "an exit status in the grace window is kept" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|read line
    #|while read more; do :; done
    #|printf '{"version":1,"request_id":"test-1","status":"completed","output":1}' > "$1"
    #|exit 4
  let result = run_script(script, wall_deadline_ms=300)
  assert_true(result.outcome is Finished(..))
  assert_eq(result.exit_code, Some(4))
}

///|
async test "the grace window bounds the wind-down, exit wait included" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  // On stdin EOF the child closes stdout at once, but writes a completed
  // result only after the grace window has ended.
  let script =
    #|read line
    #|while read more; do :; done
    #|exec 1>&-
    #|sleep 1
    #|printf '{"version":1,"request_id":"test-1","status":"completed","output":1}' > "$1"
  let result = @spawn.contract_run(
    command="sh",
    args=["-c", script, "sh", @spawn.ResultFilePlaceholder],
    input={},
    kind="probe",
    id="test-1",
    wall_deadline_ms=100,
    cancel_grace_ms=100,
  )
  assert_true(result.outcome is DidNotFinish(failure=TimedOut, ..))
}

///|
async test "a result's usage.cost_usd is the attempt's price; absent means unknown" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  fn script(cost : String) -> String {
    "read line\nprintf '{\"version\":1,\"request_id\":\"test-1\",\"status\":\"completed\",\"output\":1,\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":1,\"total_tokens\":10,\"prompt_cache_hit_tokens\":0,\"prompt_cache_miss_tokens\":9\{cost}}}' > \"$1\""
  }
  let priced = run_script(script(",\"cost_usd\":0.25"))
  assert_true(priced.outcome is Finished(..))
  assert_eq(attempt_of(priced).prompt_tokens, 9)
  assert_eq(attempt_of(priced).cost_usd, Some(0.25))
  let unpriced = run_script(script(""))
  assert_eq(attempt_of(unpriced).prompt_tokens, 9)
  assert_eq(attempt_of(unpriced).cost_usd, None)
  // A present price that is not a finite, non-negative number voids the
  // usage whole, as a bad token counter does.
  for
    cost in [
      ",\"cost_usd\":\"0.25\"", ",\"cost_usd\":-1", ",\"cost_usd\":1e999",
    ] {
    let result = run_script(script(cost))
    guard result.outcome is DidNotFinish(failure=Failed(reason), ..) else {
      fail("expected Failed")
    }
    assert_eq(reason, "malformed result file: malformed usage")
    assert_eq(attempt_of(result).prompt_tokens, 0)
    assert_eq(attempt_of(result).cost_usd, None)
    assert_eq(
      attempt_of(result).unaccounted,
      Some("the result file is malformed"),
    )
  }
}
