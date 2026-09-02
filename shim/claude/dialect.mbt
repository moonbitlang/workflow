///|
/// What the shim has learned from `claude -p --output-format stream-json`
/// so far. Purely structural: only the fields named below are read, and
/// every other line or field is ignored, so an added field upstream
/// changes nothing here.
///
/// Steps are `assistant` messages (one model call each); cost is charged
/// from each message's `usage` as it streams, falling back to the final
/// `result` object's totals only when no message carried usage. The
/// answer is the `result` text, or `structured_output` when a schema was
/// requested.
pub struct Claude {
  mut steps : Int
  mut charged : Bool
  mut answer : Json?
  mut session_id : String?
  mut num_turns : Int?
  mut cost_usd : Double?
  mut failure : String?
  mut exhausted : Bool
}

///|
/// A fresh observer.
pub fn Claude::new() -> Claude {
  {
    steps: 0,
    charged: false,
    answer: None,
    session_id: None,
    num_turns: None,
    cost_usd: None,
    failure: None,
    exhausted: false,
  }
}

///|
/// Classify one stdout line and return the contract events it implies.
pub fn Claude::observe(self : Claude, line : String) -> Array[Json] {
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
    { "type": "assistant", "message": message, .. } => {
      self.steps += 1
      events.push(@shim.agent_step(self.steps))
      if usage_of(message) is Some(usage) {
        self.charged = true
        events.push(usage)
      }
    }
    { "type": "result", .. } => {
      if !self.charged && usage_of(json) is Some(usage) {
        events.push(usage)
      }
      if json is { "session_id": String(id), .. } {
        self.session_id = Some(id)
      }
      if json is { "num_turns": Number(turns, ..), .. } {
        self.num_turns = @shim.integral(turns)
      }
      if json is { "total_cost_usd": Number(cost, ..), .. } {
        self.cost_usd = Some(cost)
      }
      let is_error = json is { "is_error": True, .. }
      let subtype = if json is { "subtype": String(subtype), .. } {
        subtype
      } else {
        "success"
      }
      let text = if json is { "result": String(text), .. } { text } else { "" }
      if subtype == "error_max_turns" {
        self.exhausted = true
      } else if is_error || subtype != "success" {
        self.failure = Some(
          if text == "" {
            "claude: \{subtype}"
          } else {
            "claude: \{subtype}: \{text}"
          },
        )
      } else if json is { "structured_output": structured, .. } &&
        !(structured is Null) {
        self.answer = Some(structured)
      } else {
        self.answer = Some(text.to_json())
      }
    }
    _ => ()
  }
  events
}

///|
/// The `usage` object Claude attaches to a message or to the result,
/// mapped onto the contract's counters: cache reads are hits; fresh input
/// and cache creation are misses; prompt tokens are all three together.
fn usage_of(container : Json) -> Json? {
  guard container
    is {
      "usage": {
        "input_tokens": Number(input, ..),
        "output_tokens": Number(output, ..),
        ..
      } as usage,
      ..
    } else {
    return None
  }
  guard @shim.integral(input) is Some(input) &&
    @shim.integral(output) is Some(output) else {
    return None
  }
  let cache_read = if usage
    is { "cache_read_input_tokens": Number(read, ..), .. } {
    @shim.integral(read).unwrap_or(0)
  } else {
    0
  }
  let cache_creation = if usage
    is { "cache_creation_input_tokens": Number(created, ..), .. } {
    @shim.integral(created).unwrap_or(0)
  } else {
    0
  }
  Some(
    @shim.usage(
      prompt_tokens=input + cache_read + cache_creation,
      completion_tokens=output,
      cache_hit=cache_read,
      cache_miss=input + cache_creation,
    ),
  )
}

///|
/// The report, once a successful result arrived: the answer plus what a
/// caller may want for resume or accounting.
pub fn Claude::report(self : Claude) -> Json? {
  guard self.answer is Some(answer) else { return None }
  let report : Json = { "answer": answer, "engine": "claude" }
  guard report is Object(fields) else { return None }
  if self.session_id is Some(id) {
    fields["session_id"] = id.to_json()
  }
  if self.num_turns is Some(turns) {
    fields["num_turns"] = turns.to_json()
  }
  if self.cost_usd is Some(cost) {
    fields["cost_usd"] = cost.to_json()
  }
  Some(report)
}

///|
test "steps and per-message usage stream; the result closes the run" {
  let state = Claude::new()
  let lines = [
    (
      #|{"type":"system","subtype":"init","session_id":"s1"}
    ),
    (
      #|{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":90,"cache_creation_input_tokens":0}}}
    ),
    (
      #|not json
    ),
    (
      #|{"type":"user","message":{"role":"user"}}
    ),
    (
      #|{"type":"assistant","message":{"usage":{"input_tokens":3,"output_tokens":7}}}
    ),
    (
      #|{"type":"result","subtype":"success","is_error":false,"result":"forty-two","session_id":"s1","num_turns":2,"total_cost_usd":0.01,"usage":{"input_tokens":13,"output_tokens":12}}
    ),
  ]
  let events : Array[Json] = []
  for line in lines {
    events.push_iter(state.observe(line).iter())
  }
  assert_eq(events, [
    @shim.agent_step(1),
    @shim.usage(
      prompt_tokens=100,
      completion_tokens=5,
      cache_hit=90,
      cache_miss=10,
    ),
    @shim.agent_step(2),
    @shim.usage(prompt_tokens=3, completion_tokens=7, cache_hit=0, cache_miss=3),
  ])
  assert_eq(state.failure, None)
  assert_eq(
    state.report(),
    Some({
      "answer": "forty-two",
      "engine": "claude",
      "session_id": "s1",
      "num_turns": 2,
      "cost_usd": 0.01,
    }),
  )
}

///|
test "result usage is charged only when no message carried any" {
  let state = Claude::new()
  let events = state.observe(
    (
      #|{"type":"result","subtype":"success","result":"ok","usage":{"input_tokens":13,"cache_read_input_tokens":2,"output_tokens":12}}
    ),
  )
  assert_eq(events, [
    @shim.usage(
      prompt_tokens=15,
      completion_tokens=12,
      cache_hit=2,
      cache_miss=13,
    ),
  ])
  assert_eq(state.report(), Some({ "answer": "ok", "engine": "claude" }))
}

///|
test "error results and the turn ceiling produce no report" {
  let failed = Claude::new()
  let _ = failed.observe(
    (
      #|{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom"}
    ),
  )
  assert_eq(failed.failure, Some("claude: error_during_execution: boom"))
  assert_eq(failed.report(), None)
  let capped = Claude::new()
  let _ = capped.observe(
    (
      #|{"type":"result","subtype":"error_max_turns","is_error":true}
    ),
  )
  assert_true(capped.exhausted)
  assert_eq(capped.failure, None)
  assert_eq(capped.report(), None)
}

///|
test "a structured answer replaces the text" {
  let state = Claude::new()
  let _ = state.observe(
    (
      #|{"type":"result","subtype":"success","result":"","structured_output":{"verdict":"real"}}
    ),
  )
  assert_eq(
    state.report(),
    Some({ "answer": { "verdict": "real" }, "engine": "claude" }),
  )
}
