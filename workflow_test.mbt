///|
/// Combinator and context tests over FAKE runners: nothing here leaves the
/// process — the engine seam is exactly one async function, so the fakes
/// exercise accounting, policies, concurrency, cancellation, and events
/// hermetically. The scripted runner dispatches on the prompt's prefix:
/// `fail:` is an agent failure THAT STILL SPENT TOKENS, `skip:` a human
/// refusal that never spawned a child, `boom:` an engine bug escaping the
/// seam, `slow:` a long child for cancellation tests, anything else a
/// success echoing its prompt.
priv suberror EngineBoom {
  EngineBoom
}

///|
fn attempt_for(call : @workflow.AgentCall) -> @workflow.AgentAttempt {
  {
    attempt_id: "sr-\{call.label}",
    steps_used: 1,
    prompt_tokens: 7,
    completion_tokens: 3,
    cost_usd: None,
  }
}

///|
async fn scripted(call : @workflow.AgentCall) -> @workflow.AgentOutcome {
  @async.pause()
  guard call.input is { "query": String(prompt), .. } else {
    fail("the scripted runner expects the explore-style input")
  }
  if prompt.strip_prefix("fail:") is Some(_) {
    return DidNotFinish(
      failure=@workflow.AgentFailure::Failed("boom"),
      attempt=Some(attempt_for(call)),
    )
  }
  if prompt.strip_prefix("skip:") is Some(_) {
    return DidNotFinish(failure=@workflow.AgentFailure::Skipped, attempt=None)
  }
  if prompt.strip_prefix("boom:") is Some(_) {
    raise EngineBoom
  }
  if prompt.strip_prefix("slow:") is Some(_) {
    @async.sleep(2_000)
  }
  Finished(value={ "echo": prompt }, attempt=attempt_for(call))
}

///|
fn scripted_workflow(
  max_concurrent? : Int = 8,
  max_calls? : Int,
  on_event? : (@workflow.WorkflowEvent) -> Unit,
) -> @workflow.Workflow raise {
  @workflow.Workflow(
    runner=@workflow.Runner(scripted),
    max_concurrent~,
    max_calls?,
    on_event?,
  )
}

///|
async test "agent returns the report value and accounts tokens" {
  let wf = scripted_workflow()
  let value = wf.agent(prompt="hello", kind="scout")
  assert_eq(value, { "echo": "hello" })
  assert_eq(wf.tokens_spent(), 10)
  assert_eq(wf.calls_made(), 1)
}

///|
async test "a failed agent still charges its attempt's tokens" {
  let wf = scripted_workflow()
  guard wf.try_agent(prompt="fail:a", kind="scout")
    is Err(@workflow.AgentFailed(label="fail:a", failure=Failed("boom"))) else {
    fail("expected AgentFailed with the runner's reason")
  }
  assert_eq(wf.tokens_spent(), 10)
}

///|
async test "a skipped call spends nothing and replays as a refusal" {
  let wf = scripted_workflow()
  guard wf.try_agent(prompt="skip:a", kind="scout")
    is Err(@workflow.AgentFailed(failure=Skipped, ..)) else {
    fail("expected the skip to surface as AgentFailed(Skipped)")
  }
  assert_eq(wf.tokens_spent(), 0)
}

///|
async test "the launch allowance ignores calls cancelled while queued" {
  let wf = scripted_workflow(max_concurrent=1, max_calls=3)
  // One slot: `slow:a` launches and holds it while `ok-b`/`ok-c` queue.
  // Cancelling the fan-out WHILE they are queued must leave them undebited
  // — only the launched agent counts, and the fallback below still fits.
  @async.with_task_group(group => {
    let work = group.spawn(() => {
      @workflow.parallel_all([
        () => wf.agent(prompt="slow:a", kind="scout"),
        () => wf.agent(prompt="ok-b", kind="scout"),
        () => wf.agent(prompt="ok-c", kind="scout"),
      ])
    })
    group.spawn_bg(no_wait=true) <| () => {
      // Handshake, not a timer: cancel only once the first agent has
      // launched and the siblings have had scheduler turns to reach the
      // semaphore queue.
      while wf.calls_made() < 1 {
        @async.pause()
      }
      for _ in 0..<10 {
        @async.pause()
      }
      work.cancel()
    }
    let _ : Array[Json] = work.wait() catch {
      error if @async.is_cancellation_error(error) => []
      error => raise error
    }
  })
  assert_eq(wf.calls_made(), 1)
  let _ = wf.agent(prompt="ok-fallback", kind="scout")
  assert_eq(wf.calls_made(), 2)
}

///|
async test "the launch allowance refuses the call after the cap" {
  let wf = scripted_workflow(max_calls=2)
  let _ = wf.agent(prompt="one", kind="scout")
  let _ = wf.agent(prompt="two", kind="scout")
  guard wf.try_agent(prompt="three", kind="scout")
    is Err(@workflow.CallBudgetExhausted(..)) else {
    fail("expected the third launch to be refused")
  }
  assert_eq(wf.calls_made(), 2)
}

///|
async test "parallel keeps sibling successes when one agent fails" {
  let wf = scripted_workflow()
  let results = @workflow.parallel([
    () => wf.try_agent(prompt="a", kind="scout"),
    () => wf.try_agent(prompt="fail:b", kind="scout"),
    () => wf.try_agent(prompt="c", kind="scout"),
  ])
  guard results is [Ok(_), Err(@workflow.AgentFailed(..)), Ok(_)] else {
    fail("expected exactly the middle slot to fail")
  }
  assert_eq(@workflow.collect_ok(results).length(), 2)
  assert_eq(@workflow.quorum(results, need=2).length(), 2)
  let short : Array[Json] = @workflow.quorum(results, need=3) catch {
    @workflow.QuorumNotReached(need=3, ok=2, of=3) => []
    _ => fail("expected QuorumNotReached(need=3, ok=2, of=3)")
  }
  assert_eq(short.length(), 0)
  let mut reraised = false
  let _ = @workflow.all_ok(results) catch {
    @workflow.AgentFailed(label="fail:b", ..) => {
      reraised = true
      []
    }
    _ => fail("expected all_ok to re-raise the agent failure")
  }
  assert_true(reraised)
}

///|
async test "an engine error is never demoted to a policy slot" {
  let wf = scripted_workflow()
  let mut engine_error = false
  let _ : Array[Result[Json, @workflow.WorkflowError]] = @workflow.parallel([
    () => wf.try_agent(prompt="a", kind="scout"),
    () => wf.try_agent(prompt="boom:b", kind="scout"),
  ]) catch {
    EngineBoom => {
      engine_error = true
      []
    }
    _ => fail("expected the engine bug to propagate as itself")
  }
  assert_true(engine_error)
}

///|
async test "parallel_all cancels a slow sibling and the workflow survives" {
  let slow_completed : Ref[Bool] = { val: false, }
  let events : Array[String] = []
  let wf = scripted_workflow(on_event=event => events.push(render(event)))
  let _ : Array[Json] = @workflow.parallel_all([
    () => wf.agent(prompt="fail:a", kind="scout"),
    () => {
      let value = wf.agent(prompt="slow:b", kind="scout")
      slow_completed.val = true
      value
    },
  ]) catch {
    @workflow.AgentFailed(label="fail:a", ..) => []
    _ => fail("expected the failure to propagate")
  }
  assert_false(slow_completed.val)
  // The cancelled sibling still closed its event bracket.
  assert_true(events.contains("finish slow:b interrupted"))
  // The semaphore and allowance are intact: the workflow keeps working.
  let value = wf.agent(prompt="ok-after", kind="scout")
  assert_eq(value, { "echo": "ok-after" })
}

///|
async test "fan_out gives every item its own result slot" {
  let wf = scripted_workflow()
  let results = @workflow.fan_out(["p", "q", "r"], item => {
    wf.try_agent(prompt=item, kind="scout")
  })
  assert_eq(@workflow.all_ok(results).length(), 3)
  assert_eq(wf.calls_made(), 3)
}

///|
/// A kind whose input is NOT the explore shape — the `worker` slice of
/// the child contract, near enough. `agent` cannot express this; it is
/// what `agent_call` is for, so the fake answers from the input's own
/// fields rather than from a `query`.
async fn worker_runner(call : @workflow.AgentCall) -> @workflow.AgentOutcome {
  @async.pause()
  guard call.input is { "task": String(task), "worker_root": String(root), .. } else {
    return DidNotFinish(
      failure=@workflow.AgentFailure::Failed("not a worker input"),
      attempt=None,
    )
  }
  Finished(
    value={ "status": "done", "task": task, "root": root },
    attempt=attempt_for(call),
  )
}

///|
async test "agent_call carries an engine's own input shape" {
  let wf = @workflow.Workflow(runner=@workflow.Runner(worker_runner))
  let report = wf.agent_call(
    kind="worker",
    input={ "task": "rename the seam", "worker_root": "/w/1" },
    label="worker:1",
  )
  assert_eq(report, {
    "status": "done",
    "task": "rename the seam",
    "root": "/w/1",
  })
  assert_eq(wf.calls_made(), 1)
  // The same call through `agent` would have wrapped the prompt in
  // `{"query": …}`, which this engine does not accept.
  guard wf.try_agent(prompt="rename the seam", kind="worker")
    is Err(@workflow.AgentFailed(failure=Failed("not a worker input"), ..)) else {
    fail("expected the explore shape to be refused by a worker kind")
  }
}

///|
async test "agent_call's replay identity is the input the caller gave" {
  let journal = @workflow.Journal::in_memory()
  let first = @workflow.Workflow(
    runner=@workflow.Runner(worker_runner),
    journal~,
  )
  let input : Json = { "task": "rename the seam", "worker_root": "/w/1" }
  let report = first.agent_call(kind="worker", input~, label="worker:1")
  assert_eq(first.calls_made(), 1)

  // Next generation: the SAME input replays for free, and the label is
  // no part of that identity — this one is deliberately different.
  let next = @workflow.Workflow(
    runner=@workflow.Runner(worker_runner),
    journal=@workflow.Journal::in_memory(prior=journal.recorded()),
  )
  assert_eq(
    next.agent_call(kind="worker", input~, label="worker:renamed"),
    report,
  )
  assert_eq(next.calls_made(), 0)
  assert_eq(next.calls_replayed(), 1)
  // A DIFFERENT input is different work, so it runs live.
  let _ = next.agent_call(
    kind="worker",
    input={ "task": "rename the seam", "worker_root": "/w/2" },
    label="worker:2",
  )
  assert_eq(next.calls_made(), 1)
}

///|
async test "attempt folds any raising step, agent_call included" {
  let wf = scripted_workflow()
  // The fold `try_agent` gives `agent`, over the entry point that has no
  // `try_` twin of its own.
  let refused = @workflow.attempt(() => {
    wf.agent_call(
      kind="scout",
      input={ "query": "fail:worker" },
      label="worker:1",
    )
  })
  guard refused is Err(@workflow.AgentFailed(label="worker:1", ..)) else {
    fail("expected the agent failure to land in the Err slot")
  }
  // Successes pass through, and engine bugs still propagate.
  guard @workflow.attempt(() => wf.agent(prompt="ok", kind="scout")) is Ok(_) else {
    fail("expected the success to pass through")
  }
  let mut engine_error = false
  let _ : Result[Json, @workflow.WorkflowError] = @workflow.attempt(() => {
    wf.agent(prompt="boom:b", kind="scout")
  }) catch {
    EngineBoom => {
      engine_error = true
      Ok(Json::null())
    }
    _ => fail("expected the engine bug to propagate as itself")
  }
  assert_true(engine_error)
}

///|
/// Fails its first `fail_first` launches and then succeeds, reporting how
/// many launches it took: the transient shape `retry` exists for.
fn flaky_runner(fail_first : Int) -> @workflow.Runner {
  let launches : Ref[Int] = { val: 0, }
  @workflow.Runner(call => {
    @async.pause()
    launches.val += 1
    if launches.val <= fail_first {
      DidNotFinish(
        failure=@workflow.AgentFailure::TimedOut,
        attempt=Some(attempt_for(call)),
      )
    } else {
      Finished(value={ "launches": launches.val }, attempt=attempt_for(call))
    }
  })
}

///|
async test "retry re-launches a retriable failure until it succeeds" {
  let wf = @workflow.Workflow(runner=flaky_runner(2))
  let report = @workflow.retry(
    () => wf.agent(prompt="q", kind="scout", label="flaky"),
    max_retry=2,
  )
  assert_eq(report, { "launches": 3 })
  // Every attempt is a real launch, and every attempt's tokens are charged
  // — the failed ones spent them too.
  assert_eq(wf.calls_made(), 3)
  assert_eq(wf.tokens_spent(), 30)
}

///|
async test "retry raises the last attempt's failure when the budget runs out" {
  let wf = @workflow.Workflow(runner=flaky_runner(5))
  let report : Json = @workflow.retry(
    () => wf.agent(prompt="q", kind="scout", label="flaky"),
    max_retry=1,
    backoff=FixedDelay(1),
  ) catch {
    @workflow.AgentFailed(label="flaky", failure=TimedOut) => Json::null()
    _ => fail("expected the last attempt's own failure")
  }
  assert_eq(report, Json::null())
  assert_eq(wf.calls_made(), 2)
}

///|
async test "retry leaves a refusal, an engine bug, and a spent allowance alone" {
  let wf = scripted_workflow()
  let refusal : Json = @workflow.retry(
    () => wf.agent(prompt="skip:a", kind="scout", label="skip"),
    max_retry=3,
  ) catch {
    @workflow.AgentFailed(failure=Skipped, ..) => Json::null()
    _ => fail("expected the human's refusal to stand after one attempt")
  }
  assert_eq(refusal, Json::null())
  let mut engine_error = false
  let _ : Json = @workflow.retry(
    () => wf.agent(prompt="boom:b", kind="scout", label="boom"),
    max_retry=3,
  ) catch {
    EngineBoom => {
      engine_error = true
      Json::null()
    }
    _ => fail("expected the engine bug to propagate as itself")
  }
  assert_true(engine_error)
  // One launch each: neither the refusal nor the engine bug was re-run.
  assert_eq(wf.calls_made(), 2)
  let capped = scripted_workflow(max_calls=1)
  let _ = capped.agent(prompt="one", kind="scout")
  let refused : Json = @workflow.retry(
    () => capped.agent(prompt="two", kind="scout", label="two"),
    max_retry=3,
  ) catch {
    @workflow.CallBudgetExhausted(label="two") => Json::null()
    _ => fail("expected the spent allowance to refuse without re-attempts")
  }
  assert_eq(refused, Json::null())
  assert_eq(capped.calls_made(), 1)
}

///|
async test "cancellation ends a retry loop instead of restarting it" {
  let wf = scripted_workflow()
  let finished = @async.with_timeout_opt(30, () => {
    @workflow.retry(
      () => wf.agent(prompt="slow:a", kind="scout", label="slow"),
      max_retry=5,
    )
  })
  assert_true(finished is None)
  assert_eq(wf.calls_made(), 1)
}

///|
async test "max_concurrent bounds in-flight agents" {
  let in_flight : Ref[Int] = { val: 0, }
  let peak : Ref[Int] = { val: 0, }
  let runner = @workflow.Runner(call => {
    in_flight.val += 1
    if in_flight.val > peak.val {
      peak.val = in_flight.val
    }
    @async.sleep(5)
    in_flight.val -= 1
    Finished(value=Json::null(), attempt=attempt_for(call))
  })
  let wf = @workflow.Workflow(runner~, max_concurrent=1)
  let _ = @workflow.parallel_all([
    () => wf.agent(prompt="a", kind="scout"),
    () => wf.agent(prompt="b", kind="scout"),
    () => wf.agent(prompt="c", kind="scout"),
  ])
  assert_eq(peak.val, 1)
}

///|
async test "event brackets balance on success, failure, and engine error" {
  let events : Array[String] = []
  let wf = scripted_workflow(on_event=event => events.push(render(event)))
  wf.phase("Scan")
  wf.log("starting")
  let _ = wf.agent(prompt="q", kind="scout", label="scout")
  let _ = wf.try_agent(prompt="fail:x", kind="scout")
  let _ = wf.agent(prompt="boom:y", kind="scout") catch { _ => Json::null() }
  assert_eq(events, [
    "phase Scan", "log starting", "start scout scout Scan", "finish scout ok", "start fail:x scout Scan",
    "finish fail:x failed", "start boom:y scout Scan", "finish boom:y errored",
  ])
}

///|
async test "the default label is the prompt's first line, cut well-formed" {
  let labels : Array[String] = []
  let wf = scripted_workflow(on_event=event => {
    if event is @workflow.AgentStarted(label~, ..) {
      labels.push(label)
    }
  })
  let _ = wf.agent(prompt="ask one thing\nthen explain yourself", kind="scout")
  // 47 units of prose and then an astral emoji: the cut at 48 lands inside
  // that surrogate pair, so the whole pair goes rather than half of it.
  let _ = wf.agent(prompt="x".repeat(47) + "🚀 and more", kind="scout")
  let _ = wf.agent(prompt="short", kind="scout")
  assert_eq(labels, ["ask one thing…", "x".repeat(47) + "…", "short"])
}

///|
async test "outcomes and failures survive the JSON round trip" {
  let attempt : @workflow.AgentAttempt = {
    attempt_id: "sr-1",
    steps_used: 4,
    prompt_tokens: 11,
    completion_tokens: 5,
    cost_usd: None,
  }
  let outcomes : Array[@workflow.AgentOutcome] = [
    Finished(value={ "answer": 42 }, attempt~),
    DidNotFinish(
      failure=@workflow.AgentFailure::TimedOut,
      attempt=Some(attempt),
    ),
    DidNotFinish(
      failure=@workflow.AgentFailure::NoReport,
      attempt=Some(attempt),
    ),
    DidNotFinish(
      failure=@workflow.AgentFailure::MaxSteps,
      attempt=Some(attempt),
    ),
    DidNotFinish(
      failure=@workflow.AgentFailure::ContextYield,
      attempt=Some(attempt),
    ),
    DidNotFinish(failure=@workflow.AgentFailure::Skipped, attempt=None),
    DidNotFinish(failure=@workflow.AgentFailure::Failed("reason"), attempt=None),
  ]
  for outcome in outcomes {
    let back : @workflow.AgentOutcome = @json.from_json(outcome.to_json())
    assert_true(back == outcome)
  }
}

///|
async test "quorum boundaries: zero and negative thresholds collect" {
  let wf = scripted_workflow()
  let results = @workflow.parallel([
    () => wf.try_agent(prompt="fail:a", kind="scout"),
  ])
  assert_eq(@workflow.quorum(results, need=0).length(), 0)
  assert_eq(@workflow.collect_ok(results, min_ok=-1).length(), 0)
}

///|
fn render(event : @workflow.WorkflowEvent) -> String {
  match event {
    @workflow.PhaseStarted(title) => "phase \{title}"
    @workflow.Log(message) => "log \{message}"
    @workflow.AgentStarted(label~, kind~, phase~) =>
      "start \{label} \{kind} \{phase.unwrap_or("-")}"
    @workflow.AgentFinished(label~, disposition~) =>
      "finish \{label} \{disposition_word(disposition)}"
    @workflow.AgentReplayed(label~, disposition~) =>
      "replay \{label} \{disposition_word(disposition)}"
  }
}

///|
fn disposition_word(disposition : @workflow.AgentDisposition) -> String {
  match disposition {
    @workflow.Succeeded => "ok"
    @workflow.FailedAgent => "failed"
    @workflow.Interrupted => "interrupted"
    @workflow.Errored => "errored"
  }
}

///|
/// Answers with a well-formed verdict, or a stray shape when asked to; and
/// reports whether the call carried a schema, so the tests can see it.
async fn shaped_runner(call : @workflow.AgentCall) -> @workflow.AgentOutcome {
  @async.pause()
  let value : Json = if call.input is { "query": String(query), .. } &&
    query.contains("stray") {
    { "verdict": 7 }
  } else {
    { "verdict": "real", "schema_seen": call.schema is Some(_) }
  }
  Finished(value~, attempt={
    attempt_id: "sr-\{call.label}",
    steps_used: 1,
    prompt_tokens: 10,
    completion_tokens: 5,
    cost_usd: None,
  })
}

///|
struct Verdict {
  verdict : String
} derive(FromJson)

///|
async test "agent_as decodes at the boundary; a stray shape is a typed rejection" {
  let wf = @workflow.Workflow(runner=@workflow.Runner(shaped_runner))
  let verdict : Verdict = wf.agent_as(prompt="is it real?", kind="judge", schema={
    "type": "object",
  })
  assert_eq(verdict.verdict, "real")
  let stray : Result[Verdict, @workflow.WorkflowError] = wf.try_agent_as(
    prompt="stray shape please",
    kind="judge",
    label="stray",
  )
  guard stray is Err(@workflow.AgentFailed(label~, failure~)) else {
    fail("expected a typed rejection")
  }
  assert_eq(label, "stray")
  guard failure is @workflow.Failed(reason) else { fail("expected Failed") }
  assert_true(reason.has_prefix("report rejected: "))
  // The rejected report was a real, accounted call like any other.
  assert_eq(wf.calls_made(), 2)
  assert_eq(wf.tokens_spent(), 30)
}

///|
async test "the schema is part of the work identity and reaches the runner" {
  let journal = @workflow.Journal::in_memory()
  let wf = @workflow.Workflow(runner=@workflow.Runner(shaped_runner), journal~)
  let plain = wf.agent(prompt="shape me", kind="judge")
  let shaped = wf.agent(prompt="shape me", kind="judge", schema={
    "type": "object",
  })
  // Same question, different shape: different work, so no replay between them.
  assert_eq(wf.calls_made(), 2)
  assert_eq(wf.calls_replayed(), 0)
  assert_true(plain is { "schema_seen": False, .. })
  assert_true(shaped is { "schema_seen": True, .. })
  // The next generation replays the shaped call by its schema too.
  let again = @workflow.Workflow(
    runner=@workflow.Runner(shaped_runner),
    journal=@workflow.Journal::in_memory(prior=journal.recorded()),
  )
  assert_eq(
    again.agent(prompt="shape me", kind="judge", schema={ "type": "object" }),
    shaped,
  )
  assert_eq(again.calls_replayed(), 1)
  assert_eq(again.calls_made(), 0)
}

///|
/// Prices every other call, so the workflow's money total is a floor.
async fn priced_runner(call : @workflow.AgentCall) -> @workflow.AgentOutcome {
  @async.pause()
  let priced = call.label.has_prefix("priced")
  Finished(value="ok", attempt={
    attempt_id: "sr-\{call.label}",
    steps_used: 1,
    prompt_tokens: 1,
    completion_tokens: 1,
    cost_usd: if priced {
      Some(0.25)
    } else {
      None
    },
  })
}

///|
async test "cost_usd sums the engines' own figures and ignores unknowns" {
  let journal = @workflow.Journal::in_memory()
  let wf = @workflow.Workflow(runner=@workflow.Runner(priced_runner), journal~)
  let _ = wf.agent(prompt="a", kind="k", label="priced-1")
  let _ = wf.agent(prompt="b", kind="k", label="priced-2")
  let _ = wf.agent(prompt="c", kind="k", label="free")
  assert_eq(wf.cost_usd(), 0.5)
  assert_eq(wf.tokens_spent(), 6)
  // A replayed call costs nothing again — historical spend lives in the journal.
  let again = @workflow.Workflow(
    runner=@workflow.Runner(priced_runner),
    journal=@workflow.Journal::in_memory(prior=journal.recorded()),
  )
  let _ = again.agent(prompt="a", kind="k", label="priced-1")
  assert_eq(again.cost_usd(), 0.0)
  assert_eq(again.calls_replayed(), 1)
}

///|
test "a priced attempt survives the JSON round trip on both arms" {
  let priced : @workflow.AgentAttempt = {
    attempt_id: "sr-9",
    steps_used: 2,
    prompt_tokens: 7,
    completion_tokens: 3,
    cost_usd: Some(0.25),
  }
  for
    outcome in [
      @workflow.Finished(value="ok", attempt=priced),
      @workflow.DidNotFinish(failure=TimedOut, attempt=Some(priced)),
    ] {
    let json = outcome.to_json()
    assert_true(json.stringify().contains("\"cost_usd\":0.25"))
    let back : @workflow.AgentOutcome = @json.from_json(json)
    assert_true(back == outcome)
  }
}

///|
async test "a null schema is the same work as no schema" {
  let journal = @workflow.Journal::in_memory()
  let wf = @workflow.Workflow(runner=@workflow.Runner(shaped_runner), journal~)
  let _ = wf.agent(prompt="shape me", kind="judge", schema=Json::null())
  assert_eq(journal.recorded()[0].call.schema, None)
  // The next generation, asking with no schema at all, replays it.
  let again = @workflow.Workflow(
    runner=@workflow.Runner(shaped_runner),
    journal=@workflow.Journal::in_memory(prior=journal.recorded()),
  )
  let _ = again.agent(prompt="shape me", kind="judge")
  assert_eq(again.calls_replayed(), 1)
  assert_eq(again.calls_made(), 0)
}
