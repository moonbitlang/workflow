///|
/// A fixture dialect over `sh`, enough to drive every ending `respond`
/// writes end to end: each `step` line is a step, `usage` charges 10
/// prompt tokens and 1 completion token, and `answer X` is the report.
async fn sh_dialect(
  request : Request,
  script : String,
  until_cancelled : async () -> Unit,
) -> ShimResult {
  let mut steps = 0
  let mut usage : Usage? = None
  let mut answer : Json? = None
  let exit = run_cli(
    command="sh",
    args=["-c", script],
    until_cancelled~,
    // `moon test` runs with SIGINT ignored; see "Stop tears the CLI down".
    stop_signal=@signal.SIGTERM,
    observe=line => {
      match line.trim(chars="\r\n") {
        "step" => steps += 1
        "usage" => {
          let charge = Usage(
            prompt_tokens=10,
            completion_tokens=1,
            cache_hit_tokens=0,
            cache_miss_tokens=10,
          )
          usage = Some(usage.map(seen => seen.add(charge)).unwrap_or(charge))
        }
        [.. "answer ", .. text] => answer = Some(Json::string(text.to_owned()))
        _ => ()
      }
      if request.max_steps is Some(limit) && steps > limit {
        Stop
      } else {
        Continue
      }
    },
  )
  let status : Status = match exit {
    Cancelled => Interrupted("the parent closed stdin")
    Stopped => MaxStepsExhausted
    Failed(reason) => Failed(reason)
    Exited(code) =>
      match answer {
        Some(report) => Completed(report)
        None if code != 0 => Failed("sh exited \{code} without a result")
        None => NoReport
      }
  }
  ShimResult(status, usage?, steps~)
}

///|
async fn can_spawn_sh() -> Bool {
  let code = @process.run("sh", ["-c", "exit 0"]) catch { _ => return false }
  code == 0
}

///|
async fn never() -> Unit {
  @async.sleep(3_600_000)
}

///|
/// Answer `line` with the `sh_dialect` running `script`, and read back what
/// landed at the result path: `None` when no file was written.
async fn answer_with(
  line : String?,
  script? : String = "exit 0",
  until_cancelled? : async () -> Unit = never,
) -> (Json?, Array[String]) {
  let dir = @fs.tmpdir(prefix="workflow-shim-test-")
  defer (@fs.rmdir(dir, recursive=true) catch { _ => () })
  let path = "\{dir}/result.json"
  respond(Options(command="sh", result_file=path), line, name="test shim", run=(
    _,
    request,
  ) => sh_dialect(request, script, until_cancelled))
  let written = if @fs.exists(path) {
    Some(@json.parse(@fs.read_file(path).text()))
  } else {
    None
  }
  // The sibling was renamed into place: nothing else is left behind.
  (written, @fs.readdir(dir, sort=true))
}

///|
fn request_line(max_steps? : Int) -> String {
  let request : Map[String, Json] = {
    "version": 1,
    "request_id": "cr-7",
    "kind": "explore",
    "input": { "query": "q" },
  }
  if max_steps is Some(steps) {
    request["limits"] = { "max_steps": Json(steps) }
  }
  Json::object(request).stringify()
}

///|
async test "a completed run writes its report, usage, and steps, atomically" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|echo step
    #|echo usage
    #|echo step
    #|echo usage
    #|echo 'answer forty-two'
  let (written, files) = answer_with(Some(request_line()), script~)
  assert_eq(
    written,
    Some({
      "version": 1,
      "request_id": "cr-7",
      "status": "completed",
      "output": "forty-two",
      "usage": {
        "prompt_tokens": 20,
        "completion_tokens": 2,
        "total_tokens": 22,
        "prompt_cache_hit_tokens": 0,
        "prompt_cache_miss_tokens": 20,
      },
      "steps": 2,
    }),
  )
  assert_eq(files, ["result.json"])
}

///|
async test "a clean exit without an answer is no_report; a crash is failed" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let (quiet, _) = answer_with(Some(request_line()), script="echo step")
  assert_eq(
    quiet,
    Some({
      "version": 1,
      "request_id": "cr-7",
      "status": "no_report",
      "steps": 1,
    }),
  )
  let (crashed, _) = answer_with(Some(request_line()), script="exit 3")
  assert_eq(
    crashed,
    Some({
      "version": 1,
      "request_id": "cr-7",
      "status": "failed",
      "reason": "sh exited 3 without a result",
      "steps": 0,
    }),
  )
}

///|
async test "the step ceiling stops the run, and what it spent is kept" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|trap 'echo usage; exit 0' TERM
    #|echo step
    #|echo step
    #|echo step
    #|while :; do sleep 1; done
  let (written, _) = answer_with(Some(request_line(max_steps=2)), script~)
  // The over-limit step happened; its cost arrived in the grace.
  assert_eq(
    written,
    Some({
      "version": 1,
      "request_id": "cr-7",
      "status": "max_steps_exhausted",
      "usage": {
        "prompt_tokens": 10,
        "completion_tokens": 1,
        "total_tokens": 11,
        "prompt_cache_hit_tokens": 0,
        "prompt_cache_miss_tokens": 10,
      },
      "steps": 3,
    }),
  )
}

///|
async test "the parent's cancel is an interrupted result, late usage settled" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|trap 'echo usage; exit 0' TERM
    #|echo step
    #|while :; do sleep 1; done
  let (written, _) = answer_with(Some(request_line()), script~, until_cancelled=() => {
    @async.sleep(300)
  })
  assert_eq(
    written,
    Some({
      "version": 1,
      "request_id": "cr-7",
      "status": "interrupted",
      "reason": "the parent closed stdin",
      "usage": {
        "prompt_tokens": 10,
        "completion_tokens": 1,
        "total_tokens": 11,
        "prompt_cache_hit_tokens": 0,
        "prompt_cache_miss_tokens": 10,
      },
      "steps": 1,
    }),
  )
}

///|
async test "a malformed request with an id is failed; without one, no result" {
  let (written, _) = answer_with(
    Some(
      "{\"version\":1,\"request_id\":\"cr-7\",\"kind\":\"explore\",\"input\":{}}",
    ),
  )
  assert_eq(
    written,
    Some({
      "version": 1,
      "request_id": "cr-7",
      "status": "failed",
      "reason": "malformed request: `input` needs a `query` (or `prompt`) string",
    }),
  )
  // Nothing to answer: `respond` raises, and the file is never created.
  for line in [Some("not json"), Some("{\"version\":1,\"input\":\"q\"}"), None] {
    let dir = @fs.tmpdir(prefix="workflow-shim-test-")
    defer (@fs.rmdir(dir, recursive=true) catch { _ => () })
    let path = "\{dir}/result.json"
    let message = try
      respond(Options(command="sh", result_file=path), line, name="test shim", run=(
        _,
        _,
      ) => fail("must not run"))
    catch {
      NoResult(message) => message
      error => fail("expected NoResult, got \{error}")
    } noraise {
      _ => fail("expected NoResult")
    }
    assert_true(message.has_prefix("test shim: "))
    assert_false(@fs.exists(path))
  }
}

///|
async test "an error the dialect raises is a failed result" {
  let dir = @fs.tmpdir(prefix="workflow-shim-test-")
  defer (@fs.rmdir(dir, recursive=true) catch { _ => () })
  let path = "\{dir}/result.json"
  respond(
    Options(command="sh", result_file=path),
    Some(request_line()),
    name="test shim",
    run=(_, _) => fail("no schema file"),
  )
  guard @json.parse(@fs.read_file(path).text())
    is { "status": "failed", "reason": String(reason), .. } else {
    fail("expected a failed result")
  }
  assert_true(reason.has_prefix("test shim failed: "))
  assert_true(reason.contains("no schema file"))
}

///|
async test "the result replaces a stale file at the path" {
  let dir = @fs.tmpdir(prefix="workflow-shim-test-")
  defer (@fs.rmdir(dir, recursive=true) catch { _ => () })
  let path = "\{dir}/result.json"
  @fs.write_file(path, "stale")
  write_result(path, "cr-7", ShimResult(NoReport))
  assert_eq(
    @fs.read_file(path).text(),
    "{\"version\":1,\"request_id\":\"cr-7\",\"status\":\"no_report\"}\n",
  )
  assert_eq(@fs.readdir(dir), ["result.json"])
}

///|
test "the request document yields its id, kind, ceiling, and a hinted prompt" {
  let line =
    #|{"version":1,"request_id":"cr-1","kind":"explore","limits":{"max_steps":8},"input":{"query":"q","hints":"h"}}
  guard Request::parse(line) is Ok(request) else { fail("parse") }
  assert_eq(request.request_id, "cr-1")
  assert_eq(request.kind, "explore")
  assert_eq(request.max_steps, Some(8))
  assert_eq(request.prompt, "q\n\nHints: h")
  assert_eq(request.input, { "query": "q", "hints": "h" })
  assert_eq(request.schema, None)
}

///|
test "limits and schema are optional; `prompt` and a bare string are prompts" {
  let bare =
    #|{"version":1,"request_id":"r","kind":"explore","input":"bare","limits":{}}
  guard Request::parse(bare) is Ok(request) else { fail("bare") }
  assert_eq(request.max_steps, None)
  assert_eq(request.prompt, "bare")
  let prompted =
    #|{"version":1,"request_id":"r","kind":"worker","input":{"prompt":"p"},"schema":null}
  guard Request::parse(prompted) is Ok(request) else { fail("prompt") }
  assert_eq(request.kind, "worker")
  assert_eq(request.prompt, "p")
  assert_eq(request.schema, None)
  let shaped =
    #|{"version":1,"request_id":"r","kind":"explore","input":"q","schema":{"type":"object"}}
  guard Request::parse(shaped) is Ok(request) else { fail("schema") }
  assert_eq(request.schema, Some({ "type": "object" }))
}

///|
test "anything but a whole version 1 request is a typed refusal" {
  fn refusal(line : String) -> String {
    match Request::parse(line) {
      Err(problem) => problem
      Ok(_) => "accepted"
    }
  }
  assert_eq(refusal("not json"), "the request is not JSON")
  assert_eq(refusal("[1]"), "the request is not a JSON object")
  assert_eq(
    refusal("{\"request_id\":\"r\",\"kind\":\"explore\",\"input\":\"q\"}"),
    "the request has no `version`",
  )
  assert_eq(
    refusal(
      "{\"version\":2,\"request_id\":\"r\",\"kind\":\"explore\",\"input\":\"q\"}",
    ),
    "unsupported request version 2",
  )
  // The retired `workflow_contract` envelope is not a request.
  assert_eq(
    refusal(
      "{\"workflow_contract\":1,\"id\":\"cr-1\",\"kind\":\"explore\",\"input\":\"q\"}",
    ),
    "the request has no `version`",
  )
  assert_eq(
    refusal("{\"version\":1,\"kind\":\"explore\",\"input\":\"q\"}"),
    "the request has no `request_id` string",
  )
  assert_eq(
    refusal("{\"version\":1,\"request_id\":\"r\",\"input\":\"q\"}"),
    "the request has no `kind` string",
  )
  assert_eq(
    refusal("{\"version\":1,\"request_id\":\"r\",\"kind\":\"explore\"}"),
    "the request has no `input`",
  )
  assert_eq(
    refusal(
      "{\"version\":1,\"request_id\":\"r\",\"kind\":\"explore\",\"input\":{\"query\":\"  \"}}",
    ),
    "`input` needs a `query` (or `prompt`) string",
  )
}

///|
test "a malformed ceiling or schema is refused, never read as absent" {
  // A bad ceiling must not become an unbounded run.
  for
    limits in [
      "{\"max_steps\":5.5}", "{\"max_steps\":\"5\"}", "{\"max_steps\":null}", "{\"max_steps\":0}",
    ] {
    assert_true(
      Request::parse(
        "{\"version\":1,\"request_id\":\"r\",\"kind\":\"explore\",\"input\":\"q\",\"limits\":\{limits}}",
      )
      is Err("`limits.max_steps` must be an integer of at least 1"),
    )
  }
  assert_true(
    Request::parse(
      "{\"version\":1,\"request_id\":\"r\",\"kind\":\"explore\",\"input\":\"q\",\"limits\":8}",
    )
    is Err("`limits` must be a JSON object"),
  )
  assert_true(
    Request::parse(
      "{\"version\":1,\"request_id\":\"r\",\"kind\":\"explore\",\"input\":\"q\",\"schema\":\"object\"}",
    )
    is Err("`schema` must be a JSON object"),
  )
}

///|
test "argv: the result path is required; defaults, settings, and passthrough" {
  guard Options::parse([], default_command="codex") is Err(problem) else {
    fail("an argv without --result-file must not parse")
  }
  assert_true(problem.contains("--result-file"))
  guard Options::parse(["--result-file", " "], default_command="codex")
    is Err(problem) else {
    fail("a blank result path must not parse")
  }
  assert_eq(problem, "--result-file needs a path")
  guard Options::parse(["--result-file", "/r.json"], default_command="codex")
    is Ok(bare) else {
    fail("bare")
  }
  assert_eq(bare.result_file, "/r.json")
  assert_eq(bare.command, "codex")
  assert_eq(bare.model, None)
  assert_eq(bare.writable, false)
  assert_eq(bare.extra, [])
  guard Options::parse(
      [
        "--result-file", "/r.json", "--model", "m", "--cwd", "/w", "--writable",
        "--", "--model", "theirs",
      ],
      default_command="claude",
    )
    is Ok(full) else {
    fail("full")
  }
  assert_eq(full.command, "claude")
  assert_eq(full.model, Some("m"))
  assert_eq(full.cwd, Some("/w"))
  assert_eq(full.writable, true)
  // The CLI's own `--model` rode through untouched, ours stayed ours.
  assert_eq(full.extra, ["--model", "theirs"])
}

///|
test "argv: an unknown option is refused, never taken for a CLI flag" {
  guard Options::parse(
      ["--result-file", "/r.json", "--writeable"],
      default_command="claude",
    )
    is Err(problem) else {
    fail("a typo must not parse")
  }
  assert_true(problem.contains("unexpected argument '--writeable'"))
  assert_true(problem.contains("--writable"))
}

///|
test "argv separator uses the first match within a sliced view" {
  let argv = [
    "ignored", "--result-file", "/r", "--model", "m", "--", "--", "tail",
  ]
  guard Options::parse(argv[1:], default_command="codex") is Ok(options) else {
    fail("expected parsed options")
  }
  assert_eq(options.model, Some("m"))
  assert_eq(options.extra, ["--", "tail"])
  // A `--result-file` after the separator is the CLI's, not ours.
  guard Options::parse(["--", "--result-file", "/r"], default_command="codex")
    is Err(_) else {
    fail("a passthrough --result-file must not count")
  }
}
