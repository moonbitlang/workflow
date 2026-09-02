///|
async fn can_spawn_sh() -> Bool {
  let code = @process.run("sh", ["-c", "exit 0"]) catch { _ => return false }
  code == 0
}

///|
test "the v1 envelope yields kind, ceiling, and a hinted prompt" {
  let line =
    #|{"workflow_contract":1,"id":"cr-1","kind":"explore","max_steps":8,"input":{"query":"q","hints":"h"}}
  guard @shim.Request::parse(line) is Ok(request) else { fail("parse") }
  assert_eq(request.id, Some("cr-1"))
  assert_eq(request.kind, "explore")
  assert_eq(request.max_steps, Some(8))
  assert_eq(request.prompt, "q\n\nHints: h")
  assert_eq(request.input, { "query": "q", "hints": "h" })
}

///|
test "a bare input line is an explore call with no ceiling" {
  guard @shim.Request::parse("{\"query\":\"q\"}\n") is Ok(request) else {
    fail("parse")
  }
  assert_eq(request.id, None)
  assert_eq(request.kind, "explore")
  assert_eq(request.max_steps, None)
  assert_eq(request.prompt, "q")
  // `prompt` and a bare string work too.
  guard @shim.Request::parse("{\"prompt\":\"p\"}") is Ok(p) else { fail("p") }
  assert_eq(p.prompt, "p")
  guard @shim.Request::parse("\"bare\"") is Ok(bare) else { fail("bare") }
  assert_eq(bare.prompt, "bare")
}

///|
test "unknown majors, non-JSON, and promptless inputs are typed refusals" {
  assert_true(
    @shim.Request::parse("{\"workflow_contract\":2,\"input\":{}}")
    is Err("unsupported workflow_contract version 2"),
  )
  assert_true(@shim.Request::parse("not json") is Err("shim input is not JSON"))
  assert_true(
    @shim.Request::parse(
      "{\"workflow_contract\":1,\"input\":{\"query\":\"  \"}}",
    )
    is Err("shim input needs a `query` (or `prompt`) string"),
  )
}

///|
test "usage carries all five counters with a derived total" {
  assert_eq(
    @shim.usage(
      prompt_tokens=90,
      completion_tokens=10,
      cache_hit=70,
      cache_miss=20,
    ),
    {
      "event": "usage",
      "usage": {
        "prompt_tokens": 90,
        "completion_tokens": 10,
        "total_tokens": 100,
        "prompt_cache_hit_tokens": 70,
        "prompt_cache_miss_tokens": 20,
      },
    },
  )
  assert_eq(@shim.integral(3.0), Some(3))
  assert_eq(@shim.integral(1.5), None)
}

///|
async test "run_cli drains every line and reports the exit status" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let seen : Array[String] = []
  let script =
    #|read line || echo "stdin at eof"
    #|echo one
    #|echo two
    #|exit 3
  let exit = @shim.run_cli(
    command="sh",
    args=["-c", script],
    watch_stdin=false,
    observe=line => {
      seen.push(line.trim(chars="\r\n").to_owned())
      @shim.Continue
    },
  )
  // The CLI's stdin is at EOF from the start: `read` fails immediately.
  assert_eq(seen, ["stdin at eof", "one", "two"])
  assert_true(exit is @shim.Exited(3))
}

///|
async test "Stop tears the CLI down and wins over its exit status" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|echo first
    #|trap 'echo flushed; exit 0' TERM
    #|echo second
    #|while :; do sleep 1; done
    #|echo never
  let seen : Array[String] = []
  let exit = @shim.run_cli(
    command="sh",
    args=["-c", script],
    watch_stdin=false,
    // SIGTERM here: `moon test` runs with SIGINT ignored, and a
    // non-interactive sh cannot trap a signal ignored on entry (POSIX),
    // so the default SIGINT would be a silent no-op in this harness.
    stop_signal=@signal.SIGTERM,
    observe=line => {
      seen.push(line.trim(chars="\r\n").to_owned())
      if seen.length() == 2 {
        @shim.Stop
      } else {
        @shim.Continue
      }
    },
  )
  assert_true(exit is @shim.Stopped)
  // The trap ran inside the grace: its line was observed too.
  assert_eq(seen, ["first", "second", "flushed"])
}

///|
async test "an unspawnable command is a Failed exit, never a crash" {
  let exit = @shim.run_cli(
    command="/nonexistent/agent-cli-not-here",
    args=[],
    watch_stdin=false,
    observe=_ => @shim.Continue,
  )
  assert_true(exit is @shim.Failed(_))
}

///|
test "a fractional step ceiling is a malformed request, never no ceiling" {
  // Cross-engine review finding: `integral` rejected 5.5 but the request
  // then read as "no max_steps" — an unbounded run from a bad envelope.
  assert_true(
    @shim.Request::parse(
      "{\"workflow_contract\":1,\"max_steps\":5.5,\"input\":{\"query\":\"q\"}}",
    )
    is Err("shim input max_steps must be an integer"),
  )
}
