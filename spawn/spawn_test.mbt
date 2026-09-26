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
async fn run_script(script : String) -> @spawn.ContractResult {
  @spawn.contract_run(
    command="sh",
    args=["-c", script],
    input={ "query": "q" },
    kind="probe",
    id="test-1",
    wall_deadline_ms=10_000,
  )
}

///|
async test "events and the report line are drained and accounted" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|read line
    #|printf '{"timestamp":"t","level":"INFO","source":"s","event":"agent_step","step":1}\n'
    #|printf 'not json at all\n'
    #|printf '{"timestamp":"t","level":"INFO","source":"s","event":"usage","usage":{"prompt_tokens":90,"completion_tokens":10,"total_tokens":100,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":90}}\n'
    #|printf '{"timestamp":"t","level":"INFO","source":"s","event":"agent_step","step":2}\n'
    #|printf '{"subrun_report": {"answer": "forty-two"}}\n'
  let result = run_script(script)
  guard result.terminal is Captured else { fail("expected Captured") }
  assert_eq(result.report, Some(({ "answer": "forty-two" } : Json)))
  assert_eq(result.steps_used, 2)
  assert_eq(result.prompt_tokens, 90)
  assert_eq(result.completion_tokens, 10)
}

///|
async test "a clean exit without a report is NoReport" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|read line
    #|printf '{"timestamp":"t","level":"INFO","source":"s","event":"agent_step","step":1}\n'
  let result = run_script(script)
  guard result.terminal is NoReport else { fail("expected NoReport") }
  assert_eq(result.report, None)
}

///|
async test "an observed step exhaustion is MaxSteps" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|read line
    #|printf '{"timestamp":"t","level":"INFO","source":"s","event":"max_steps_exhausted"}\n'
  guard run_script(script).terminal is MaxSteps else {
    fail("expected MaxSteps")
  }
}

///|
async test "a reported turn failure classifies as Failed" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|read line
    #|printf '{"timestamp":"t","level":"ERROR","source":"s","event":"turn_failed","error":"the model refused"}\n'
  guard run_script(script).terminal is Failed(reason) else {
    fail("expected Failed")
  }
  assert_true(reason.contains("refused"))
}

///|
async test "a spawn failure folds into Failed, never a crash" {
  let result = @spawn.contract_run(
    command="/nonexistent/engine-not-here",
    args=[],
    input={ "query": "q" },
    kind="probe",
    id="test-2",
    wall_deadline_ms=2_000,
  )
  match result.terminal {
    Failed(_) => ()
    // Some sandboxes surface spawn refusal as an immediate empty exit.
    NoReport => ()
    _ => fail("expected the missing binary to degrade, not crash")
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
  let path = "\{dir}/journal.jsonl"
  let live =
    #|read line
    #|printf '{"timestamp":"t","level":"INFO","source":"s","event":"usage","usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":7}}\n'
    #|printf '{"subrun_report": %s}\n' "$line"
  let wf1 = @workflow.Workflow(
    runner=@spawn.contract_runner(launch=_ => {
      @spawn.LaunchSpec(command="sh", args=["-c", live])
    }),
    journal=@workflow.Journal::load(path),
  )
  // The report echoes the input line: the v1 request envelope carrying
  // the call's kind and exact input — self-contained, no argv needed.
  let first = wf1.agent(
    prompt="hello",
    kind="probe",
    hints="from a foreign engine",
  )
  assert_eq(first, {
    "workflow_contract": 1,
    "id": "cr-1",
    "kind": "probe",
    "input": { "query": "hello", "hints": "from a foreign engine" },
  })
  assert_eq(wf1.tokens_spent(), 10)
  // Resume: served from the journal, no process spawned.
  let poisoned =
    #|read line
    #|printf '{"subrun_report": {"wrong": true}}\n'
  let wf2 = @workflow.Workflow(
    runner=@spawn.contract_runner(launch=_ => {
      @spawn.LaunchSpec(command="sh", args=["-c", poisoned])
    }),
    journal=@workflow.Journal::load(path),
  )
  assert_eq(
    wf2.agent(prompt="hello", kind="probe", hints="from a foreign engine"),
    first,
  )
  assert_eq(wf2.calls_made(), 0)
  assert_eq(wf2.calls_replayed(), 1)
  @fs.rmdir(dir, recursive=true) catch {
    _ => ()
  }
}

///|
async test "malformed numeric events are ignored whole, never truncated" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  // A fractional step, a fractional token count, and a usage object
  // missing its total: each ignored WHOLE — then one valid pair counts.
  let script =
    #|read line
    #|printf '{"event":"agent_step","step":2.9}\n'
    #|printf '{"event":"usage","usage":{"prompt_tokens":90.5,"completion_tokens":10,"total_tokens":100,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":90}}\n'
    #|printf '{"event":"usage","usage":{"prompt_tokens":50,"completion_tokens":5}}\n'
    #|printf '{"event":"agent_step","step":1}\n'
    #|printf '{"event":"usage","usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":7}}\n'
    #|printf '{"subrun_report": {"ok": true}}\n'
  let result = run_script(script)
  guard result.terminal is Captured else { fail("expected Captured") }
  assert_eq(result.steps_used, 1)
  assert_eq(result.prompt_tokens, 7)
  assert_eq(result.completion_tokens, 3)
}

///|
async test "the request envelope carries the call's ceiling and schema" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  // A child that reports the request line it received.
  let script =
    #|read line
    #|printf '{"subrun_report": %s}\n' "$line"
  let result = @spawn.contract_run(
    command="sh",
    args=["-c", script],
    input={ "query": "q" },
    kind="probe",
    id="test-2",
    max_steps=3,
    schema={ "type": "object" },
    wall_deadline_ms=10_000,
  )
  guard result.terminal is Captured else { fail("expected Captured") }
  assert_true(
    result.report
    is Some(
      {
        "workflow_contract": Number(1, ..),
        "id": "test-2",
        "kind": "probe",
        "max_steps": Number(3, ..),
        "schema": { "type": "object", .. },
        "input": { "query": "q", .. },
        ..
      }
    ),
  )
}

///|
async test "usage.cost_usd is summed into the attempt; absent means unknown" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let priced =
    #|read line
    #|printf '{"event":"usage","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":10,"cost_usd":0.25}}\n'
    #|printf '{"event":"usage","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":10,"cost_usd":0.5}}\n'
    #|printf '{"subrun_report": "ok"}\n'
  let result = run_script(priced)
  assert_eq(result.cost_usd, Some(0.75))
  assert_eq(result.prompt_tokens, 20)
  let unpriced =
    #|read line
    #|printf '{"event":"usage","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":10}}\n'
    #|printf '{"subrun_report": "ok"}\n'
  assert_eq(run_script(unpriced).cost_usd, None)
}

///|
async test "a malformed, negative, or infinite cost_usd invalidates the whole usage line" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|read line
    #|printf '{"event":"usage","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":10,"cost_usd":"0.25"}}\n'
    #|printf '{"event":"usage","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":10,"cost_usd":-1}}\n'
    #|printf '{"event":"usage","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":10,"cost_usd":1e999}}\n'
    #|printf '{"event":"usage","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":1,"cost_usd":0.5}}\n'
    #|printf '{"subrun_report": "ok"}\n'
  let result = run_script(script)
  // Only the well-formed line counts — tokens and money together.
  assert_eq(result.prompt_tokens, 1)
  assert_eq(result.completion_tokens, 1)
  assert_eq(result.cost_usd, Some(0.5))
}

///|
/// A transport-2 child: `sh -c SCRIPT sh {result_file}`, so the script finds
/// its result path in `$1`.
async fn run_result_file_script(
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
    transport=ResultFile,
  )
}

///|
async test "a result file is the result, and stdout is not read" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  // The stdout lines would count as a report and usage under transport 1.
  let script =
    #|read line
    #|printf '{"subrun_report": {"forged": true}}\n'
    #|printf '{"event":"usage","usage":{"prompt_tokens":999,"completion_tokens":1,"total_tokens":1000,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":999}}\n'
    #|printf '{"version":1,"request_id":"test-1","status":"completed","output":{"answer":42},"usage":{"prompt_tokens":90,"completion_tokens":10,"total_tokens":100,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":90},"steps":2}' > "$1"
  let result = run_result_file_script(script)
  guard result.terminal is Captured else { fail("expected Captured") }
  assert_eq(result.report, Some(({ "answer": 42 } : Json)))
  assert_eq(result.steps_used, 2)
  assert_eq(result.prompt_tokens, 90)
  assert_eq(result.completion_tokens, 10)
  assert_eq(result.unaccounted, None)
  assert_eq(result.exit_code, Some(0))
}

///|
async test "the transport 2 request names its id, kind, input, and limits" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|read line
    #|printf '{"version":1,"request_id":"test-1","status":"completed","output":%s}' "$line" > "$1"
  let result = run_result_file_script(script, max_steps=7)
  assert_eq(
    result.report,
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
  let clean = run_result_file_script("read line")
  guard clean.terminal is Failed(reason) else { fail("expected Failed") }
  assert_eq(reason, "the child exited 0 without writing a result")
  assert_eq(clean.unaccounted, Some("the child left no result"))
  let crashed = run_result_file_script("read line; exit 3")
  guard crashed.terminal is Failed(reason) else { fail("expected Failed") }
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
  guard run_result_file_script(other).terminal is Failed(reason) else {
    fail("expected Failed")
  }
  assert_eq(reason, "malformed result file: answers request test-9, not test-1")
  let fractional =
    #|read line
    #|printf '{"version":1,"request_id":"test-1","status":"completed","output":1,"usage":{"prompt_tokens":1.5,"completion_tokens":0,"total_tokens":0,"prompt_cache_hit_tokens":0,"prompt_cache_miss_tokens":0}}' > "$1"
  let result = run_result_file_script(fractional)
  guard result.terminal is Failed(reason) else { fail("expected Failed") }
  assert_eq(reason, "malformed result file: malformed usage")
  assert_eq(result.unaccounted, Some("the result file is malformed"))
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
  let max_steps = run_result_file_script(script("max_steps_exhausted"))
  assert_true(max_steps.terminal is MaxSteps)
  // A result without usage leaves the counters unaccounted.
  assert_eq(max_steps.unaccounted, Some("the child's result carries no usage"))
  assert_true(run_result_file_script(script("no_report")).terminal is NoReport)
  assert_true(
    run_result_file_script(script("context_yield")).terminal is ContextYield,
  )
  guard run_result_file_script(script("interrupted")).terminal is Failed(reason) else {
    fail("expected Failed")
  }
  assert_eq(reason, "interrupted: why")
  guard run_result_file_script(script("failed")).terminal is Failed(reason) else {
    fail("expected Failed")
  }
  assert_eq(reason, "why")
  guard run_result_file_script(script("finished")).terminal is Failed(reason) else {
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
  let result = run_result_file_script(script, wall_deadline_ms=300)
  guard result.terminal is TimedOut else { fail("expected TimedOut") }
  assert_eq(result.prompt_tokens, 5)
  assert_eq(result.steps_used, 1)
  assert_eq(result.unaccounted, None)
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
  let result = run_result_file_script(script)
  assert_true(result.terminal is Captured)
  assert_eq(result.exit_code, Some(4))
}

///|
async test "the transport and the argv must agree" {
  let missing = @spawn.contract_run(
    command="sh",
    args=["-c", "read line"],
    input={},
    kind="probe",
    id="test-1",
    wall_deadline_ms=10_000,
    transport=ResultFile,
  )
  guard missing.terminal is Failed(reason) else { fail("expected Failed") }
  assert_eq(reason, "the ResultFile transport needs {result_file} in the argv")
  let stray = @spawn.contract_run(
    command="sh",
    args=["-c", "read line", "sh", "{result_file}"],
    input={},
    kind="probe",
    id="test-1",
    wall_deadline_ms=10_000,
  )
  guard stray.terminal is Failed(reason) else { fail("expected Failed") }
  assert_eq(
    reason, "the argv names {result_file}, but the transport is StdoutEvents",
  )
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
  let result = run_result_file_script(script)
  guard result.terminal is Captured else { fail("expected Captured") }
  assert_eq(result.report, Some(Json::string("ok")))
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
  let result = run_result_file_script(script)
  assert_true(result.terminal is MaxSteps)
  assert_eq(result.steps_used, 7)
  assert_eq(result.unaccounted, Some("the child's result carries no usage"))
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
  let result = run_result_file_script(script, wall_deadline_ms=300)
  assert_true(result.terminal is TimedOut)
  assert_eq(result.unaccounted, Some("the result file is malformed"))
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
  let result = run_result_file_script(script, wall_deadline_ms=300)
  assert_true(result.terminal is Captured)
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
    transport=ResultFile,
  )
  assert_true(result.terminal is TimedOut)
}
