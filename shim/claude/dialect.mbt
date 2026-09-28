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
/// result (`usage`).
priv struct Claude {
  mut steps : Int
  snapshots : Map[String, @shim.Usage]
  /// The result's true totals, priced when it stated a price.
  mut charged : @shim.Usage?
  mut answer : Json?
  mut session_id : String?
  mut num_turns : Int?
  mut cost_usd : Double?
  mut failure : String?
  mut exhausted : Bool
}

///|
/// A fresh observer.
fn Claude::Claude() -> Claude {
  {
    steps: 0,
    snapshots: {},
    charged: None,
    answer: None,
    session_id: None,
    num_turns: None,
    cost_usd: None,
    failure: None,
    exhausted: false,
  }
}

///|
/// Classify one stdout line into the state.
fn Claude::observe(self : Claude, line : String) -> Unit {
  let trimmed = line.trim(chars="\r\n")
  if trimmed == "" {
    return
  }
  let json = @json.parse(trimmed) catch { _ => return }
  match json {
    { "type": "assistant", "message": message, .. } => {
      // An id-less message (never seen from the CLI, but not a reason to
      // miscount) is its own step.
      let id = if message is { "id": String(id), .. } {
        id
      } else {
        "anonymous-\{self.steps + 1}"
      }
      let first_seen = !self.snapshots.contains(id)
      if first_seen {
        self.steps += 1
      }
      match cost_of(message) {
        Some(cost) => self.snapshots[id] = cost
        None =>
          if first_seen {
            self.snapshots[id] = @shim.Usage(
              prompt_tokens=0,
              completion_tokens=0,
              cache_hit_tokens=0,
              cache_miss_tokens=0,
            )
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
        self.charged = Some(
          @shim.Usage(
            prompt_tokens=cost.prompt_tokens,
            completion_tokens=cost.completion_tokens,
            cache_hit_tokens=cost.cache_hit_tokens,
            cache_miss_tokens=cost.cache_miss_tokens,
            cost_usd?=self.cost_usd,
          ),
        )
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
        self.answer = Some(Json(text))
      }
    }
    _ => ()
  }
}

///|
/// The `usage` object Claude attaches to a message or to the result,
/// mapped onto the contract's counters: cache reads are hits; fresh input
/// and cache creation are misses; prompt tokens are all three together.
fn cost_of(container : Json) -> @shim.Usage? {
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
    @shim.Usage(
      prompt_tokens=input + cache_read + cache_creation,
      completion_tokens=output,
      cache_hit_tokens=cache_read,
      cache_miss_tokens=input + cache_creation,
    ),
  )
}

///|
/// What the run cost: the result's true totals when it arrived; else, for a
/// run cut short before its result (a step ceiling, a cancel, a crash), the
/// sum of the last snapshot of every message seen, unpriced. `None` when
/// nothing was observed — unknown, not free.
fn Claude::usage(self : Claude) -> @shim.Usage? {
  if self.charged is Some(total) {
    return Some(total)
  }
  let mut total : @shim.Usage? = None
  for _, cost in self.snapshots {
    total = Some(
      match total {
        Some(sum) => sum.add(cost)
        None => cost
      },
    )
  }
  total
}

///|
/// How the run ended, given how the CLI did. A result the CLI itself
/// classified (a failure, its own turn cap) wins over the exit status; a
/// nonzero exit without any result is a failure, a clean one `no_report`.
fn Claude::status(self : Claude, exit : @shim.CliExit) -> @shim.Status {
  match exit {
    Cancelled => Interrupted("the parent closed stdin")
    Stopped => MaxStepsExhausted
    Failed(reason) => Failed(reason)
    Exited(code) =>
      if self.failure is Some(error) {
        Failed(error)
      } else if self.exhausted {
        MaxStepsExhausted
      } else if self.report() is Some(report) {
        Completed(report)
      } else if code != 0 {
        Failed("claude exited \{code} without a result")
      } else {
        NoReport
      }
  }
}

///|
/// The result file's content for a run that ended with `exit`.
fn Claude::result(self : Claude, exit : @shim.CliExit) -> @shim.ShimResult {
  @shim.ShimResult(self.status(exit), usage?=self.usage(), steps=self.steps)
}

///|
/// The report, once a successful result arrived: the answer plus what a
/// caller may want for resume or accounting.
fn Claude::report(self : Claude) -> Json? {
  guard self.answer is Some(answer) else { return None }
  let fields : Map[String, Json] = { "answer": answer, "engine": "claude" }
  if self.session_id is Some(id) {
    fields["session_id"] = Json(id)
  }
  if self.num_turns is Some(turns) {
    fields["num_turns"] = Json(turns)
  }
  if self.cost_usd is Some(cost) {
    fields["cost_usd"] = Json(cost)
  }
  Some(Json::object(fields))
}

///|
/// Feed `lines` to a fresh observer.
fn observed(lines : Array[String]) -> Claude {
  let state = Claude()
  for line in lines {
    state.observe(line)
  }
  state
}

///|
/// Lines recorded from claude 2.1.258 (`--output-format stream-json
/// --verbose`, Haiku 4.5, prompt "Reply with exactly the single word:
/// ok"), trimmed to the fields that matter. Both `assistant` lines are
/// the SAME message (thinking block, then text block).
test "one message across two content blocks is one step; the result charges" {
  let state = observed([
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
  ])
  assert_eq(state.result(Exited(0)).to_json(request_id="r"), {
    "version": 1,
    "request_id": "r",
    "status": "completed",
    "output": {
      "answer": "ok",
      "engine": "claude",
      "session_id": "s1",
      "num_turns": 1,
      "cost_usd": 0.0173444,
    },
    // The result's totals, not the per-message snapshots.
    "usage": {
      "prompt_tokens": 21294,
      "completion_tokens": 43,
      "total_tokens": 21337,
      "prompt_cache_hit_tokens": 13615,
      "prompt_cache_miss_tokens": 7679,
      "cost_usd": 0.0173444,
    },
    "steps": 1,
  })
}

///|
test "a run cut short settles the last snapshot of every message seen" {
  let state = observed([
    (
      #|{"type":"assistant","message":{"id":"msg_1","usage":{"input_tokens":10,"cache_read_input_tokens":90,"output_tokens":2}}}
    ),
    (
      #|{"type":"assistant","message":{"id":"msg_1","usage":{"input_tokens":10,"cache_read_input_tokens":90,"output_tokens":5}}}
    ),
    (
      #|{"type":"assistant","message":{"id":"msg_2","usage":{"input_tokens":3,"output_tokens":7}}}
    ),
  ])
  // msg_1's LAST snapshot (5 output tokens) plus msg_2's, unpriced.
  let usage : Json = {
    "prompt_tokens": 103,
    "completion_tokens": 12,
    "total_tokens": 115,
    "prompt_cache_hit_tokens": 90,
    "prompt_cache_miss_tokens": 13,
  }
  assert_eq(state.result(Stopped).to_json(request_id="r"), {
    "version": 1,
    "request_id": "r",
    "status": "max_steps_exhausted",
    "usage": usage,
    "steps": 2,
  })
  assert_eq(state.result(Cancelled).to_json(request_id="r"), {
    "version": 1,
    "request_id": "r",
    "status": "interrupted",
    "reason": "the parent closed stdin",
    "usage": usage,
    "steps": 2,
  })
  assert_eq(state.result(Exited(137)).to_json(request_id="r"), {
    "version": 1,
    "request_id": "r",
    "status": "failed",
    "reason": "claude exited 137 without a result",
    "usage": usage,
    "steps": 2,
  })
}

///|
test "nothing observed is unknown usage, never zero" {
  assert_eq(observed([]).result(Exited(0)).to_json(request_id="r"), {
    "version": 1,
    "request_id": "r",
    "status": "no_report",
    "steps": 0,
  })
  assert_eq(
    observed([])
    .result(Failed("cannot spawn claude: ENOENT"))
    .to_json(request_id="r"),
    {
      "version": 1,
      "request_id": "r",
      "status": "failed",
      "reason": "cannot spawn claude: ENOENT",
      "steps": 0,
    },
  )
}

///|
test "error results and the turn ceiling produce no report" {
  let failed = observed([
    (
      #|{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom"}
    ),
  ])
  assert_eq(
    failed.status(Exited(1)),
    Failed("claude: error_during_execution: boom"),
  )
  let capped = observed([
    (
      #|{"type":"result","subtype":"error_max_turns","is_error":true}
    ),
  ])
  assert_eq(capped.status(Exited(0)), MaxStepsExhausted)
  assert_eq(capped.report(), None)
}

///|
test "a structured answer replaces the text" {
  let state = observed([
    (
      #|{"type":"result","subtype":"success","result":"","structured_output":{"verdict":"real"}}
    ),
  ])
  assert_eq(
    state.report(),
    Some({ "answer": { "verdict": "real" }, "engine": "claude" }),
  )
}

///|
// Synthetic framing and partial-message cases, not a new CLI dialect.
test "missing usage blocks preserve the last valid snapshot and one step" {
  let missing = "{\"type\":\"assistant\",\"message\":{\"id\":\"m\"}}\r\n"
  let state = observed([
    "", "\r\n", "not json", missing, "{\"type\":\"assistant\",\"message\":{\"id\":\"m\",\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}}",
    missing,
  ])
  assert_eq(state.steps, 1)
  assert_eq(state.result(Exited(0)).to_json(request_id="r"), {
    "version": 1,
    "request_id": "r",
    "status": "no_report",
    "usage": {
      "prompt_tokens": 3,
      "completion_tokens": 2,
      "total_tokens": 5,
      "prompt_cache_hit_tokens": 0,
      "prompt_cache_miss_tokens": 3,
    },
    "steps": 1,
  })
  state.observe(
    "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"你好🌙\"}\r\n",
  )
  assert_eq(
    state.report(),
    Some({ "answer": "你好🌙", "engine": "claude" }),
  )
}
