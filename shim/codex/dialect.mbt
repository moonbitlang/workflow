///|
/// What the shim has learned from `codex exec --json` so far. Purely
/// structural: only the fields named below are read.
///
/// Steps are completed items other than reasoning and notices (a
/// message, a command, a file change, a tool call); cost arrives per
/// turn on `turn.completed`; the answer is the last `agent_message` text,
/// parsed as JSON when a schema was requested. An `error` ITEM is a
/// notice (recorded from codex-cli 0.151: "Configured service tier … will
/// be omitted"), not a failure — the run goes on and usually completes.
/// Only `turn.failed` and a top-level `error` event end a run without a
/// report.
struct Codex {
  mut steps : Int
  mut thread_id : String?
  mut last_message : String?
  mut failure : String?
  notices : Array[String]
}

///|
/// A fresh observer.
fn Codex::Codex() -> Codex {
  { steps: 0, thread_id: None, last_message: None, failure: None, notices: [], }
}

///|
/// Classify one stdout line and return the contract events it implies.
fn Codex::observe(self : Codex, line : String) -> Array[Json] {
  let events : Array[Json] = []
  let trimmed = line.trim(chars="\r\n")
  if trimmed == "" {
    return events
  }
  guard (Some(@json.parse(trimmed.to_owned())) catch { _ => None })
    is Some(json) else {
    return events
  }
  match json {
    { "type": "thread.started", "thread_id": String(id), .. } =>
      self.thread_id = Some(id)
    { "type": "item.completed", "item": { "type": "reasoning", .. }, .. } => ()
    {
      "type": "item.completed",
      "item": { "type": "error", "message": String(message), .. },
      ..
    } => self.notices.push(message)
    { "type": "item.completed", "item": { "type": "error", .. }, .. } => ()
    { "type": "item.completed", "item": item, .. } => {
      self.steps += 1
      events.push(@shim.agent_step(self.steps))
      if item is { "type": "agent_message", "text": String(text), .. } {
        self.last_message = Some(text)
      }
    }
    {
      "type": "turn.completed",
      "usage": {
        "input_tokens": Number(input, ..),
        "output_tokens": Number(output, ..),
        ..
      } as usage,
      ..
    } => {
      let cached = if usage is { "cached_input_tokens": Number(cached, ..), .. } {
        @shim.integral(cached).unwrap_or(0)
      } else {
        0
      }
      if @shim.integral(input) is Some(input) &&
        @shim.integral(output) is Some(output) {
        let hit = cached.min(input)
        events.push(
          @shim.usage(
            prompt_tokens=input,
            completion_tokens=output,
            cache_hit=hit,
            cache_miss=input - hit,
          ),
        )
      }
    }
    { "type": "turn.failed", "error": { "message": String(message), .. }, .. }
    | { "type": "error", "message": String(message), .. } =>
      if self.failure is None {
        self.failure = Some("codex: \{message}")
      }
    _ => ()
  }
  events
}

///|
/// The report, once an agent message arrived: the answer (parsed when
/// `structured`, the text otherwise), the thread id for resume, and any
/// notices the CLI raised along the way.
fn Codex::report(self : Codex, structured~ : Bool) -> Json? {
  guard self.last_message is Some(text) else { return None }
  let answer : Json = if structured {
    @json.parse(text) catch {
      _ => text.to_json()
    }
  } else {
    text.to_json()
  }
  let report : Json = { "answer": answer, "engine": "codex" }
  guard report is Object(fields) else { return None }
  if self.thread_id is Some(id) {
    fields["thread_id"] = id.to_json()
  }
  if !self.notices.is_empty() {
    fields["notices"] = self.notices.to_json()
  }
  Some(report)
}

///|
/// Lines recorded from codex-cli 0.151.0 (`exec --json`, gpt-5.3-codex-spark,
/// prompt "Reply with exactly the single word: ok"), trimmed to the fields
/// that matter. The two `error` items are the service-tier notice.
test "notices are neither steps nor failures; the turn still reports" {
  let state = Codex()
  let lines = [
    (
      #|{"type":"thread.started","thread_id":"t1"}
    ),
    (
      #|{"type":"item.completed","item":{"id":"i0","type":"error","message":"Configured service tier `priority` is not advertised as supported for model `gpt-5.3-codex-spark` and will be omitted from requests."}}
    ),
    (
      #|{"type":"turn.started"}
    ),
    (
      #|{"type":"item.completed","item":{"id":"i1","type":"error","message":"Configured service tier `priority` is not advertised as supported for model `gpt-5.3-codex-spark` and will be omitted from requests."}}
    ),
    (
      #|{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"ok"}}
    ),
    (
      #|{"type":"turn.completed","usage":{"input_tokens":13829,"cached_input_tokens":4608,"cache_write_input_tokens":0,"output_tokens":67,"reasoning_output_tokens":60}}
    ),
  ]
  let events : Array[Json] = []
  for line in lines {
    events.push_iter(state.observe(line).iter())
  }
  assert_eq(events, [
    @shim.agent_step(1),
    @shim.usage(
      prompt_tokens=13829,
      completion_tokens=67,
      cache_hit=4608,
      cache_miss=9221,
    ),
  ])
  assert_eq(state.failure, None)
  assert_eq(
    state.report(structured=false),
    Some({
      "answer": "ok",
      "engine": "codex",
      "thread_id": "t1",
      "notices": [
        "Configured service tier `priority` is not advertised as supported for model `gpt-5.3-codex-spark` and will be omitted from requests.",
        "Configured service tier `priority` is not advertised as supported for model `gpt-5.3-codex-spark` and will be omitted from requests.",
      ],
    }),
  )
}

///|
test "commands and messages are steps; reasoning is not; the last message wins" {
  let state = Codex()
  let lines = [
    (
      #|{"type":"item.completed","item":{"id":"i1","type":"reasoning","text":"hmm"}}
    ),
    (
      #|{"type":"item.completed","item":{"id":"i2","type":"command_execution","command":"ls","exit_code":0}}
    ),
    (
      #|{"type":"item.completed","item":{"id":"i3","type":"agent_message","text":"draft"}}
    ),
    (
      #|{"type":"item.completed","item":{"id":"i4","type":"agent_message","text":"forty-two"}}
    ),
  ]
  let events : Array[Json] = []
  for line in lines {
    events.push_iter(state.observe(line).iter())
  }
  assert_eq(events, [
    @shim.agent_step(1),
    @shim.agent_step(2),
    @shim.agent_step(3),
  ])
  assert_eq(
    state.report(structured=false),
    Some({ "answer": "forty-two", "engine": "codex" }),
  )
}

///|
test "a structured answer is parsed; unparseable text stays text" {
  let state = Codex()
  let _ = state.observe(
    (
      #|{"type":"item.completed","item":{"type":"agent_message","text":"{\"verdict\":\"real\"}"}}
    ),
  )
  assert_eq(
    state.report(structured=true),
    Some({ "answer": { "verdict": "real" }, "engine": "codex" }),
  )
  let prose = Codex()
  let _ = prose.observe(
    (
      #|{"type":"item.completed","item":{"type":"agent_message","text":"no json here"}}
    ),
  )
  assert_eq(
    prose.report(structured=true),
    Some({ "answer": "no json here", "engine": "codex" }),
  )
}

///|
test "turn and stream errors are failures; the first one wins" {
  let state = Codex()
  let _ = state.observe(
    (
      #|{"type":"turn.failed","error":{"message":"quota"}}
    ),
  )
  let _ = state.observe(
    (
      #|{"type":"error","message":"later"}
    ),
  )
  assert_eq(state.failure, Some("codex: quota"))
  assert_eq(state.report(structured=false), None)
}
