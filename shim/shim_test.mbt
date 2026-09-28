///|
async fn can_spawn_sh() -> Bool {
  let code = @process.run("sh", ["-c", "exit 0"]) catch { _ => return false }
  code == 0
}

///|
/// A cancel signal that never comes: a test's stdin is not a parent's pipe.
async fn never() -> Unit {
  @async.sleep(3_600_000)
}

///|
test "the result document: output or reason by status, usage and steps when known" {
  let usage = @shim.Usage(
    prompt_tokens=90,
    completion_tokens=10,
    cache_hit_tokens=70,
    cache_miss_tokens=20,
  )
  assert_eq(
    @shim.ShimResult(Completed({ "answer": 42 }), usage~, steps=2).to_json(
      request_id="r",
    ),
    {
      "version": 1,
      "request_id": "r",
      "status": "completed",
      "output": { "answer": 42 },
      "usage": {
        "prompt_tokens": 90,
        "completion_tokens": 10,
        "total_tokens": 100,
        "prompt_cache_hit_tokens": 70,
        "prompt_cache_miss_tokens": 20,
      },
      "steps": 2,
    },
  )
  // Unknown usage is absent, never zero.
  assert_eq(@shim.ShimResult(NoReport).to_json(request_id="r"), {
    "version": 1,
    "request_id": "r",
    "status": "no_report",
  })
  assert_eq(
    @shim.ShimResult(MaxStepsExhausted, steps=9).to_json(request_id="r"),
    {
      "version": 1,
      "request_id": "r",
      "status": "max_steps_exhausted",
      "steps": 9,
    },
  )
  assert_eq(
    @shim.ShimResult(Interrupted("cancelled")).to_json(request_id="r"),
    {
      "version": 1,
      "request_id": "r",
      "status": "interrupted",
      "reason": "cancelled",
    },
  )
  assert_eq(@shim.ShimResult(Failed("boom")).to_json(request_id="r"), {
    "version": 1,
    "request_id": "r",
    "status": "failed",
    "reason": "boom",
  })
}

///|
test "usage carries a stated price, zero included; a sum is priced only when both are" {
  let priced = @shim.Usage(
    prompt_tokens=3,
    completion_tokens=2,
    cache_hit_tokens=1,
    cache_miss_tokens=2,
    cost_usd=0.0,
  )
  assert_eq(
    @shim.ShimResult(NoReport, usage=priced).to_json(request_id="r").stringify(),
    "{\"version\":1,\"request_id\":\"r\",\"status\":\"no_report\",\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2,\"total_tokens\":5,\"prompt_cache_hit_tokens\":1,\"prompt_cache_miss_tokens\":2,\"cost_usd\":0}}",
  )
  assert_eq(
    priced.add(priced),
    @shim.Usage(
      prompt_tokens=6,
      completion_tokens=4,
      cache_hit_tokens=2,
      cache_miss_tokens=4,
      cost_usd=0.0,
    ),
  )
  let unpriced = @shim.Usage(
    prompt_tokens=1,
    completion_tokens=1,
    cache_hit_tokens=0,
    cache_miss_tokens=1,
  )
  assert_eq(
    priced.add(unpriced),
    @shim.Usage(
      prompt_tokens=4,
      completion_tokens=3,
      cache_hit_tokens=1,
      cache_miss_tokens=3,
    ),
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
    until_cancelled=never,
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
    until_cancelled=never,
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
async test "the parent's cancel is graceful: late lines still reach observe" {
  guard can_spawn_sh() else {
    println("skipped: cannot spawn sh")
    return
  }
  let script =
    #|trap 'echo flushed; exit 0' TERM
    #|echo started
    #|while :; do sleep 1; done
  let seen : Array[String] = []
  let exit = @shim.run_cli(
    command="sh",
    args=["-c", script],
    until_cancelled=() => @async.sleep(300),
    stop_signal=@signal.SIGTERM,
    observe=line => {
      seen.push(line.trim(chars="\r\n").to_owned())
      @shim.Continue
    },
  )
  assert_true(exit is @shim.Cancelled)
  assert_eq(seen, ["started", "flushed"])
}

///|
async test "an unspawnable command is a Failed exit, never a crash" {
  let exit = @shim.run_cli(
    command="/nonexistent/agent-cli-not-here",
    args=[],
    until_cancelled=never,
    observe=_ => @shim.Continue,
  )
  assert_true(exit is @shim.Failed(_))
}
