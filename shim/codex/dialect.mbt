///|
/// What the shim has learned from `codex exec --json` so far. Purely
/// structural: only the fields named below are read.
///
/// Steps are completed items other than reasoning and notices (a
/// message, a command, a file change, a tool call); cost arrives per
/// turn on `turn.completed` and is summed; the answer is the last
/// `agent_message` text,
/// parsed as JSON when a schema was requested. An `error` ITEM is a
/// notice (recorded from codex-cli 0.151: "Configured service tier … will
/// be omitted"), not a failure — the run goes on and usually completes.
/// Only `turn.failed` and a top-level `error` event end a run without a
/// report.
priv struct Codex {
  mut steps : Int
  mut thread_id : String?
  mut last_message : String?
  mut failure : String?
  notices : Array[String]
  /// The turns' usage, summed; `None` until a turn reported some.
  mut usage : @shim.Usage?
}

///|
/// A fresh observer.
fn Codex::Codex() -> Codex {
  {
    steps: 0,
    thread_id: None,
    last_message: None,
    failure: None,
    notices: [],
    usage: None,
  }
}

///|
/// Classify one stdout line into the state.
fn Codex::observe(self : Codex, line : String) -> Unit {
  let trimmed = line.trim(chars="\r\n")
  if trimmed == "" {
    return
  }
  let json = @json.parse(trimmed) catch { _ => return }
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
        let turn = @shim.Usage(
          prompt_tokens=input,
          completion_tokens=output,
          cache_hit_tokens=hit,
          cache_miss_tokens=input - hit,
        )
        self.usage = Some(
          match self.usage {
            Some(seen) => seen.add(turn)
            None => turn
          },
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
}

///|
/// How the run ended, given how the CLI did: a turn failure wins over the
/// exit status; a nonzero exit without a message is a failure, a clean one
/// `no_report`.
fn Codex::status(
  self : Codex,
  exit : @shim.CliExit,
  structured~ : Bool,
) -> @shim.Status {
  match exit {
    Cancelled => Interrupted("the parent closed stdin")
    Stopped => MaxStepsExhausted
    Failed(reason) => Failed(reason)
    Exited(code) =>
      if self.failure is Some(error) {
        Failed(error)
      } else if self.report(structured~) is Some(report) {
        Completed(report)
      } else if code != 0 {
        Failed("codex exited \{code} without a message")
      } else {
        NoReport
      }
  }
}

///|
/// The result file's content for a run that ended with `exit`.
fn Codex::result(
  self : Codex,
  exit : @shim.CliExit,
  structured~ : Bool,
) -> @shim.ShimResult {
  @shim.ShimResult(
    self.status(exit, structured~),
    usage?=self.usage,
    steps=self.steps,
  )
}

///|
/// The report, once an agent message arrived: the answer (parsed when
/// `structured`, the text otherwise), the thread id for resume, and any
/// notices the CLI raised along the way.
fn Codex::report(self : Codex, structured~ : Bool) -> Json? {
  guard self.last_message is Some(text) else { return None }
  let answer : Json = if structured {
    @json.parse(text) catch {
      _ => Json(text)
    }
  } else {
    Json(text)
  }
  let fields : Map[String, Json] = { "answer": answer, "engine": "codex" }
  if self.thread_id is Some(id) {
    fields["thread_id"] = Json(id)
  }
  if !self.notices.is_empty() {
    fields["notices"] = Json(self.notices)
  }
  Some(Json::object(fields))
}

///|
/// Feed `lines` to a fresh observer.
fn observed(lines : Array[String]) -> Codex {
  let state = Codex()
  for line in lines {
    state.observe(line)
  }
  state
}

///|
/// Lines recorded from codex-cli 0.151.0 (`exec --json`, gpt-5.3-codex-spark,
/// prompt "Reply with exactly the single word: ok"), trimmed to the fields
/// that matter. The two `error` items are the service-tier notice.
test "notices are neither steps nor failures; the turn still reports" {
  let state = observed([
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
  ])
  assert_eq(state.failure, None)
  assert_eq(state.result(Exited(0), structured=false).to_json(request_id="r"), {
    "version": 1,
    "request_id": "r",
    "status": "completed",
    "output": {
      "answer": "ok",
      "engine": "codex",
      "thread_id": "t1",
      "notices": [
        "Configured service tier `priority` is not advertised as supported for model `gpt-5.3-codex-spark` and will be omitted from requests.",
        "Configured service tier `priority` is not advertised as supported for model `gpt-5.3-codex-spark` and will be omitted from requests.",
      ],
    },
    // Codex states no price: the usage has none.
    "usage": {
      "prompt_tokens": 13829,
      "completion_tokens": 67,
      "total_tokens": 13896,
      "prompt_cache_hit_tokens": 4608,
      "prompt_cache_miss_tokens": 9221,
    },
    "steps": 1,
  })
}

///|
test "commands and messages are steps; reasoning is not; the last message wins" {
  let state = observed([
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
  ])
  assert_eq(state.steps, 3)
  assert_eq(
    state.report(structured=false),
    Some({ "answer": "forty-two", "engine": "codex" }),
  )
}

///|
test "every turn's usage is summed" {
  let turn =
    #|{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":7}}
  let state = observed([turn, turn])
  assert_eq(state.result(Exited(0), structured=false).to_json(request_id="r"), {
    "version": 1,
    "request_id": "r",
    "status": "no_report",
    "usage": {
      "prompt_tokens": 200,
      "completion_tokens": 14,
      "total_tokens": 214,
      "prompt_cache_hit_tokens": 80,
      "prompt_cache_miss_tokens": 120,
    },
    "steps": 0,
  })
}

///|
/// Verified live on codex-cli 0.151: usage arrives only on
/// `turn.completed`, which an interrupted turn never prints — so a capped
/// or cancelled run reports NO usage, never an invented zero.
test "a run stopped before its turn completed carries no usage" {
  let state = observed([
    (
      #|{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"ls","exit_code":0}}
    ),
    (
      #|{"type":"item.completed","item":{"id":"i2","type":"command_execution","command":"pwd","exit_code":0}}
    ),
  ])
  assert_eq(state.result(Stopped, structured=false).to_json(request_id="r"), {
    "version": 1,
    "request_id": "r",
    "status": "max_steps_exhausted",
    "steps": 2,
  })
  assert_eq(state.result(Cancelled, structured=false).to_json(request_id="r"), {
    "version": 1,
    "request_id": "r",
    "status": "interrupted",
    "reason": "the parent closed stdin",
    "steps": 2,
  })
  assert_eq(
    state.status(Exited(2), structured=false),
    Failed("codex exited 2 without a message"),
  )
}

///|
test "a structured answer is parsed; unparseable text stays text" {
  let state = observed([
    (
      #|{"type":"item.completed","item":{"type":"agent_message","text":"{\"verdict\":\"real\"}"}}
    ),
  ])
  assert_eq(
    state.report(structured=true),
    Some({ "answer": { "verdict": "real" }, "engine": "codex" }),
  )
  let prose = observed([
    (
      #|{"type":"item.completed","item":{"type":"agent_message","text":"no json here"}}
    ),
  ])
  assert_eq(
    prose.report(structured=true),
    Some({ "answer": "no json here", "engine": "codex" }),
  )
}

///|
test "turn and stream errors are failures; the first one wins" {
  let state = observed([
    (
      #|{"type":"turn.failed","error":{"message":"quota"}}
    ),
    (
      #|{"type":"error","message":"later"}
    ),
  ])
  assert_eq(state.failure, Some("codex: quota"))
  assert_eq(state.status(Exited(1), structured=false), Failed("codex: quota"))
  assert_eq(state.report(structured=false), None)
}

///|
// Synthetic framing cases: invalid lines must not erase the previous answer.
test "CRLF and Unicode reports survive malformed lines with no metadata" {
  assert_eq(Codex().report(structured=false), None)
  let state = observed([
    "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"你好🌙\"}}\r\n",
    "", "\r\n", "not json",
  ])
  assert_eq(state.steps, 1)
  assert_eq(
    state.report(structured=false),
    Some({ "answer": "你好🌙", "engine": "codex" }),
  )
}
