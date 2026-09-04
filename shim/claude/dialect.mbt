///|
/// What the shim has learned from `claude -p --output-format stream-json`
/// so far. Purely structural: only the fields named below are read, and
/// every other line or field is ignored, so an added field upstream
/// changes nothing here.
///
/// The stream emits one `assistant` line PER CONTENT BLOCK (thinking,
/// text, tool_use) of the same message, each carrying that message's
/// running usage snapshot; the final `result` carries the run's true
/// totals (its `output_tokens` include thinking). So a step is a DISTINCT
/// message id, cost is charged once from the result, and the per-message
/// snapshots serve only as the fallback for a run cut short before its
/// result (`settle`).
struct Claude {
  mut steps : Int
  snapshots : Map[String, Cost]
  mut charged : Bool
  mut answer : Json?
  mut session_id : String?
  mut num_turns : Int?
  mut cost_usd : Double?
  mut failure : String?
  mut exhausted : Bool
}

///|
/// One usage reading, in the contract's counters.
priv struct Cost {
  prompt : Int
  completion : Int
  hit : Int
  miss : Int
}

///|
fn Cost::event(self : Cost, price? : Double) -> Json {
  @shim.usage(
    prompt_tokens=self.prompt,
    completion_tokens=self.completion,
    cache_hit=self.hit,
    cache_miss=self.miss,
    cost_usd?=price,
  )
}

///|
/// A fresh observer.
fn Claude::Claude() -> Claude {
  {
    steps: 0,
    snapshots: {},
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
fn Claude::observe(self : Claude, line : String) -> Array[Json] {
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
      // An id-less message (never seen from the CLI, but not a reason to
      // miscount) is its own step.
      let id = if message is { "id": String(id), .. } {
        id
      } else {
        "anonymous-\{self.steps + 1}"
      }
      if !self.snapshots.contains(id) {
        self.steps += 1
        events.push(@shim.agent_step(self.steps))
      }
      match cost_of(message) {
        Some(cost) => self.snapshots[id] = cost
        None =>
          if !self.snapshots.contains(id) {
            self.snapshots[id] = { prompt: 0, completion: 0, hit: 0, miss: 0, }
          }
      }
    }
    { "type": "result", .. } => {
      if json is { "session_id": String(id), .. } {
        self.session_id = Some(id)
      }
      if json is { "num_turns": Number(turns, ..), .. } {
        self.num_turns = @shim.integral(turns)
      }
      if json is { "total_cost_usd": Number(cost, ..), .. } {
        self.cost_usd = Some(cost)
      }
      if cost_of(json) is Some(cost) {
        self.charged = true
        events.push(cost.event(price?=self.cost_usd))
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
fn cost_of(container : Json) -> Cost? {
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
  Some({
    prompt: input + cache_read + cache_creation,
    completion: output,
    hit: cache_read,
    miss: input + cache_creation,
  })
}

///|
/// The cost to charge when the run ended WITHOUT a result (a step ceiling,
/// a cancel, a crash): the sum of the last snapshot of every message
/// seen. `None` once the result has charged the true totals, or when
/// nothing was observed.
fn Claude::settle(self : Claude) -> Json? {
  if self.charged || self.snapshots.is_empty() {
    return None
  }
  let mut total : Cost = { prompt: 0, completion: 0, hit: 0, miss: 0, }
  for _, cost in self.snapshots {
    total = {
      prompt: total.prompt + cost.prompt,
      completion: total.completion + cost.completion,
      hit: total.hit + cost.hit,
      miss: total.miss + cost.miss,
    }
  }
  Some(total.event())
}

///|
/// The report, once a successful result arrived: the answer plus what a
/// caller may want for resume or accounting.
fn Claude::report(self : Claude) -> Json? {
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
/// Lines recorded from claude 2.1.258 (`--output-format stream-json
/// --verbose`, Haiku 4.5, prompt "Reply with exactly the single word:
/// ok"), trimmed to the fields that matter. Both `assistant` lines are
/// the SAME message (thinking block, then text block).
test "one message across two content blocks is one step; the result charges" {
  let state = Claude()
  let lines = [
    (
      #|{"type":"system","subtype":"init","session_id":"s1","uuid":"u0"}
    ),
    (
      #|{"type":"rate_limit_event","uuid":"u1"}
    ),
    (
      #|{"type":"system","subtype":"thinking_tokens","uuid":"u2"}
    ),
    (
      #|{"type":"assistant","message":{"id":"msg_1","content":[{"type":"thinking"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":7669,"cache_read_input_tokens":13615,"output_tokens":4}},"uuid":"u3"}
    ),
    (
      #|{"type":"assistant","message":{"id":"msg_1","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":7669,"cache_read_input_tokens":13615,"output_tokens":4}},"uuid":"u4"}
    ),
    (
      #|{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"s1","num_turns":1,"total_cost_usd":0.0173444,"usage":{"input_tokens":10,"cache_creation_input_tokens":7669,"cache_read_input_tokens":13615,"output_tokens":43,"output_tokens_details":{"thinking_tokens":37}}}
    ),
  ]
  let events : Array[Json] = []
  for line in lines {
    events.push_iter(state.observe(line).iter())
  }
  assert_eq(events, [
    @shim.agent_step(1),
    @shim.usage(
      prompt_tokens=21294,
      completion_tokens=43,
      cache_hit=13615,
      cache_miss=7679,
      cost_usd=0.0173444,
    ),
  ])
  assert_eq(state.steps, 1)
  assert_eq(state.settle(), None)
  assert_eq(
    state.report(),
    Some({
      "answer": "ok",
      "engine": "claude",
      "session_id": "s1",
      "num_turns": 1,
      "cost_usd": 0.0173444,
    }),
  )
}

///|
test "a run cut short settles the last snapshot of every message seen" {
  let state = Claude()
  let lines = [
    (
      #|{"type":"assistant","message":{"id":"msg_1","usage":{"input_tokens":10,"cache_read_input_tokens":90,"output_tokens":2}}}
    ),
    (
      #|{"type":"assistant","message":{"id":"msg_1","usage":{"input_tokens":10,"cache_read_input_tokens":90,"output_tokens":5}}}
    ),
    (
      #|{"type":"assistant","message":{"id":"msg_2","usage":{"input_tokens":3,"output_tokens":7}}}
    ),
  ]
  let events : Array[Json] = []
  for line in lines {
    events.push_iter(state.observe(line).iter())
  }
  assert_eq(events, [@shim.agent_step(1), @shim.agent_step(2)])
  // msg_1's LAST snapshot (5 output tokens) plus msg_2's.
  assert_eq(
    state.settle(),
    Some(
      @shim.usage(
        prompt_tokens=103,
        completion_tokens=12,
        cache_hit=90,
        cache_miss=13,
      ),
    ),
  )
  assert_eq(state.report(), None)
}

///|
test "error results and the turn ceiling produce no report" {
  let failed = Claude()
  let _ = failed.observe(
    (
      #|{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom"}
    ),
  )
  assert_eq(failed.failure, Some("claude: error_during_execution: boom"))
  assert_eq(failed.report(), None)
  let capped = Claude()
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
  let state = Claude()
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
