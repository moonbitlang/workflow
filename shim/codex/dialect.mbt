///|
/// What the shim has learned from `codex exec --json` so far. Purely
/// structural: only the fields named below are read.
///
/// Steps are completed items other than reasoning (a message, a command,
/// a file change, a tool call); cost arrives per turn on
/// `turn.completed`; the answer is the last `agent_message` text, parsed
/// as JSON when a schema was requested.
pub struct Codex {
  mut steps : Int
  mut thread_id : String?
  mut last_message : String?
  mut failure : String?
}

///|
/// A fresh observer.
pub fn Codex::new() -> Codex {
  { steps: 0, thread_id: None, last_message: None, failure: None, }
}

///|
/// Classify one stdout line and return the contract events it implies.
pub fn Codex::observe(self : Codex, line : String) -> Array[Json] {
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
    { "type": "item.completed", "item": item, .. } => {
      self.steps += 1
      events.push(@shim.agent_step(self.steps))
      match item {
        { "type": "agent_message", "text": String(text), .. } =>
          self.last_message = Some(text)
        { "type": "error", "message": String(message), .. } =>
          if self.failure is None {
            self.failure = Some("codex: \{message}")
          }
        _ => ()
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
/// `structured`, the text otherwise) plus the thread id for resume.
pub fn Codex::report(self : Codex, structured~ : Bool) -> Json? {
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
  Some(report)
}

///|
test "items are steps, turns carry usage, the last message is the answer" {
  let state = Codex::new()
  let lines = [
    (
      #|{"type":"thread.started","thread_id":"t1"}
    ),
    (
      #|{"type":"turn.started"}
    ),
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
    (
      #|{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":9}}
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
    @shim.usage(
      prompt_tokens=100,
      completion_tokens=9,
      cache_hit=60,
      cache_miss=40,
    ),
  ])
  assert_eq(
    state.report(structured=false),
    Some({ "answer": "forty-two", "engine": "codex", "thread_id": "t1" }),
  )
}

///|
test "a structured answer is parsed; unparseable text stays text" {
  let state = Codex::new()
  let _ = state.observe(
    (
      #|{"type":"item.completed","item":{"type":"agent_message","text":"{\"verdict\":\"real\"}"}}
    ),
  )
  assert_eq(
    state.report(structured=true),
    Some({ "answer": { "verdict": "real" }, "engine": "codex" }),
  )
  let prose = Codex::new()
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
  let state = Codex::new()
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
