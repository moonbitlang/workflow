///|
/// THE CHILD CONTRACT, and its one implementation (`docs/child-contract.md`).
///
/// A workflow agent can be any process that speaks it:
///
/// - the launch names `{result_file}` in the child's argv; the runner
///   replaces it with a fresh path in a private directory of its own;
/// - the runner writes ONE request line on the child's stdin — the request
///   document `{"version": 1, "request_id", "kind", "input", "limits"?:
///   {"max_steps"}, "schema"?}` — and holds the pipe open: closing it is
///   the graceful-cancel signal, not the end of input. The request is
///   self-contained, so it never depends on engine-specific argv (argv
///   remains deployment configuration);
/// - the child writes ONE result file at that path when it is over. Its
///   stdout is drained unread — it is for humans — so nothing a child (or a
///   leaky tool) prints can pose as a result;
/// - after `wall_deadline_ms` the runner closes stdin and grants
///   `cancel_grace_ms` to flush and exit — a `completed` result landing in
///   the grace window still counts — then terminates the child.
///
/// `openseek run` and this module's shims speak it; a shim around any other
/// engine (a Rust CLI, a shell script) needs only to translate framing.
/// External cancellation of the CALLER is never folded into a terminal: it
/// re-raises after teardown, per structured concurrency.
let default_cancel_grace_ms : Int = 5_000

///|
/// The argv placeholder the runner replaces with the result file's path. A
/// launch whose argv does not name it is a launch error, reported as
/// `Failed`: the child would have nowhere to write its result.
pub const ResultFilePlaceholder : String = "{result_file}"

///|
/// How a contract run ended. `Captured` means a `completed` result arrived
/// — whether its CONTENT is acceptable is the caller's judgment, at the
/// layer that knows the report schema.
pub enum ContractTerminal {
  Captured
  NoReport
  MaxSteps
  ContextYield
  TimedOut
  Failed(String)
} derive(Eq)

///|
/// The dot-callable form of the derived equality methods is a migration
/// convenience, not API: compare with `==` / `!=` (through the `Eq`
/// trait) instead.
#deprecated("Use == / != (the Eq trait) instead of the attached equal/not_equal method")
#doc(hidden)
pub extend ContractTerminal with Eq::{equal, not_equal}

///|
/// One contract run's outcome: the RAW report (when a `completed` result
/// arrived) plus the cost the child's result accounted for.
pub struct ContractResult {
  report : Json?
  terminal : ContractTerminal
  steps_used : Int
  prompt_tokens : Int
  completion_tokens : Int
  /// The result's `usage.cost_usd`: the engine's own price, `None` when it
  /// stated none.
  cost_usd : Double?
  /// Why the counters above may fall short of what the child spent: `Some`
  /// when a launched child left no usable result (it crashed, was killed,
  /// or its file was malformed), or its result carried no usage. `None`
  /// means the counters are the child's own account.
  unaccounted : String?
  /// The child's exit status, when it exited within the runner's watch.
  /// Kept beside a result, so an abnormal exit after a valid result stays
  /// visible instead of being masked by it.
  exit_code : Int?
}

///|
/// JSON has one number type, so an `Int` field arrives as a `Number`;
/// reject a fractional value rather than silently truncating it.
fn integral(value : Double) -> Int? {
  let rounded = value.to_int()
  if rounded.to_double() == value {
    Some(rounded)
  } else {
    None
  }
}

///|
/// Run one child over the contract: spawn it, feed the request line, drain
/// its stdout, enforce the wall deadline with its grace window, read its
/// result file, and tear the child down on every path. Crash isolation is
/// structural: a dead or unspawnable child is a `Failed` terminal, never a
/// dead caller. External cancellation re-raises after teardown.
pub async fn contract_run(
  command~ : String,
  args~ : Array[String],
  input~ : Json,
  kind~ : String,
  id~ : String,
  max_steps? : Int,
  schema? : Json,
  wall_deadline_ms~ : Int,
  cancel_grace_ms? : Int = default_cancel_grace_ms,
  cwd? : String,
  extra_env? : Map[String, String],
) -> ContractResult {
  // A child told nowhere to write its result would fail in a way that looks
  // like its own fault.
  guard args.any(arg => arg.contains(ResultFilePlaceholder)) else {
    return launch_failed(
      "the argv must name \{ResultFilePlaceholder}, where the child writes its result",
    )
  }
  // A private directory per launch, so no other process can have left a file
  // at the path, and nothing of this one outlives the call.
  let result_dir = @fs.tmpdir(prefix="workflow-result-") catch {
    error => return launch_failed("no directory for the result file: \{error}")
  }
  defer (@fs.rmdir(result_dir, recursive=true) catch { _ => () })
  let result_path = "\{result_dir}/result.json"
  let args = args.map(arg => {
    arg.replace_all(old=ResultFilePlaceholder, new=result_path)
  })
  let mut exit_code : Int? = None
  // Whether a child process started: a failure before that spent nothing, one
  // after it may have spent anything.
  let mut launched = false
  let mut failure : String? = None
  let mut timed_out = false
  // The group call is itself fold-guarded: a spawn failure can surface
  // ASYNCHRONOUSLY (the spawn's internal reaper task raising at group
  // exit, e.g. EAGAIN under fork pressure), bypassing the per-call
  // catches inside. Cancellation bypasses every catch and unwinds; anything
  // else becomes a Failed terminal — a loaded machine must degrade the run, never
  // crash the caller.
  try
    @async.with_task_group() <| group => {
      let (child_stdin, stdin_writer) = @process.write_to_process() catch {
        error => {
          failure = Some("child pipes unavailable: \{error}")
          return
        }
      }
      // Cleanup lives in `defer`, not in `catch` arms: cancellation is a
      // signal that bypasses `catch` and unwinds only through `defer` /
      // `errdefer`. Closing a pipe and cancelling a process are idempotent,
      // so the deferred teardown also covers the explicit closes below.
      defer stdin_writer.close()
      let (stdout_reader, child_stdout) = @process.read_from_process() catch {
        error => {
          failure = Some("child pipes unavailable: \{error}")
          return
        }
      }
      defer stdout_reader.close()
      // `no_wait`: the group terminates the child at teardown rather than
      // waiting for an exit that may only come once its stdin is closed.
      let process = @process.spawn(
        group,
        command,
        args,
        inherit_env=true,
        // Credentials that only exist in the caller's memory ride this
        // overlay into the child's environment — argv would be visible
        // in `ps`, the environment is not.
        extra_env?,
        stdin=child_stdin,
        stdout=child_stdout,
        cwd?=cwd.map(dir => dir.view()),
        no_wait=true,
      ) catch {
        error => {
          failure = Some("child spawn failed: \{error}")
          return
        }
      }
      defer process.cancel()
      launched = true
      // Opaque bytes: a line reader would reject output that is not UTF-8,
      // and this stdout is not the protocol. Draining keeps the child from
      // blocking on a full pipe.
      async fn drain() -> Unit {
        while stdout_reader.read_some(max_len=4096) is Some(_) {

        }
      }
      async fn feed_and_drain() -> Unit {
        // One request line; the pipe stays open, EOF is the cancel signal,
        // not the end of input. The write sits INSIDE the deadline scope: a
        // request larger than the pipe capacity against a child that never
        // reads must hit the wall deadline, not block forever.
        let request = request_line(id~, kind~, input~, max_steps?, schema?)
        stdin_writer.write("\{request.stringify()}\n")
        drain()
      }
      try {
        match @async.with_timeout_opt(wall_deadline_ms, feed_and_drain) {
          Some(_) =>
            // Clean EOF: the child closed stdout. Keep its exit status beside
            // the result. Bounded: a child that closed stdout but lingers
            // falls through to the cancel below.
            match @async.with_timeout_opt(2_000, () => process.wait()) {
              Some(code) => exit_code = Some(code)
              None => ()
            }
          None => {
            // Deadline: graceful cancel first — close stdin, let the child
            // flush; a completed result written in the grace window still
            // counts.
            timed_out = true
            stdin_writer.close()
            // The grace window bounds the whole wind-down: flushing, and the
            // exit status worth keeping beside a result. A child still
            // running when it ends is terminated, and a result it writes
            // later does not count.
            let _ = @async.with_timeout_opt(cancel_grace_ms, () => {
              drain()
              exit_code = Some(process.wait())
            })
          }
        }
      } catch {
        error => {
          // A pipe failure: the deferred teardown stops the child; fold the
          // error into the terminal. Cancellation never reaches a `catch`;
          // it unwinds through the defers above.
          if failure is None {
            failure = Some("child stream failed: \{error}")
          }
          return
        }
      }
    }
  catch {
    error =>
      if failure is None {
        failure = Some("child runner failed: \{error}")
      }
  }
  result_file_outcome(
    result_path,
    id~,
    timed_out~,
    launched~,
    runner_failure=failure,
    exit_code~,
  )
}

///|
/// A run that failed before a child was launched: nothing was spent.
fn launch_failed(reason : String) -> ContractResult {
  {
    report: None,
    terminal: Failed(reason),
    steps_used: 0,
    prompt_tokens: 0,
    completion_tokens: 0,
    cost_usd: None,
    unaccounted: None,
    exit_code: None,
  }
}

///|
/// The one request line: the request document (`version: 1`) whose
/// `request_id` the child echoes in its result. `schema` rides along only
/// when the caller passed one, and an engine that cannot honour it must
/// refuse the request rather than ignore it.
fn request_line(
  id~ : String,
  kind~ : String,
  input~ : Json,
  max_steps? : Int,
  schema? : Json,
) -> Json {
  let fields : Map[String, Json] = {
    "version": 1,
    "request_id": Json(id),
    "kind": Json(kind),
    "input": input,
  }
  if max_steps is Some(steps) {
    fields["limits"] = { "max_steps": Json(steps) }
  }
  if schema is Some(schema) {
    fields["schema"] = schema
  }
  Json::object(fields)
}

///|
/// A child's result, as far as this runner reads it.
priv struct ChildResult {
  status : String
  output : Json?
  reason : String?
  /// The child's account, when the result carried usage.
  usage : ChildUsage?
  /// Model requests, when the result said.
  steps : Int?
}

///|
/// The part of a result's `usage` this runner charges.
priv struct ChildUsage {
  prompt_tokens : Int
  completion_tokens : Int
  /// The engine's own price, when it stated one.
  cost_usd : Double?
}

///|
/// Decode a result document, checking that it answers request `id`. The
/// document is the engine's own, so this reads only what the classification
/// needs and ignores the rest.
fn decode_result(json : Json, id~ : String) -> Result[ChildResult, String] {
  guard json is Object(fields) else { return Err("not a JSON object") }
  guard fields.get("version") is Some(Number(version, ..)) &&
    integral(version) is Some(1) else {
    return Err("not a version 1 result")
  }
  guard fields.get("request_id") is Some(String(echoed)) else {
    return Err("no request_id")
  }
  guard echoed == id else { return Err("answers request \{echoed}, not \{id}") }
  guard fields.get("status") is Some(String(status)) else {
    return Err("no status")
  }
  let reason = match fields.get("reason") {
    Some(String(reason)) => Some(reason)
    _ => None
  }
  match status {
    "completed" if fields.get("output") is None =>
      return Err("a completed result without output")
    "completed" | "no_report" | "max_steps_exhausted" => ()
    "context_yield" | "aborted" | "interrupted" | "failed" if reason is None =>
      return Err("a \{status} result without a reason")
    "context_yield" | "aborted" | "interrupted" | "failed" => ()
    other => return Err("unknown status \{other}")
  }
  // Usage is whole or absent: a partial or fractional counter voids it, and
  // so does a present `cost_usd` that is not a
  // finite, non-negative number. Steps are independent of it.
  let usage = match fields.get("usage") {
    None => None
    Some(
      {
        "prompt_tokens": Number(prompt, ..),
        "completion_tokens": Number(completion, ..),
        "total_tokens": Number(total, ..),
        "prompt_cache_hit_tokens": Number(hit, ..),
        "prompt_cache_miss_tokens": Number(miss, ..),
        ..
      } as usage
    ) => {
      let cost_usd = match usage {
        { "cost_usd": Number(cost, ..), .. } if cost >= 0.0 &&
          !cost.is_inf() &&
          !cost.is_nan() => Some(cost)
        { "cost_usd": _, .. } => return Err("malformed usage")
        _ => None
      }
      match
        (
          integral(prompt),
          integral(completion),
          integral(total),
          integral(hit),
          integral(miss),
        ) {
        (Some(prompt), Some(completion), Some(_), Some(_), Some(_)) if prompt >=
          0 &&
          completion >= 0 =>
          Some({
            prompt_tokens: prompt,
            completion_tokens: completion,
            cost_usd,
          })
        _ => return Err("malformed usage")
      }
    }
    Some(_) => return Err("malformed usage")
  }
  let steps = match fields.get("steps") {
    None => None
    Some(Number(steps, ..)) =>
      match integral(steps) {
        Some(steps) if steps >= 0 => Some(steps)
        _ => return Err("malformed steps")
      }
    Some(_) => return Err("malformed steps")
  }
  Ok({ status, output: fields.get("output"), reason, usage, steps, })
}

///|
/// Classify a run from its result file. The file is authoritative:
/// a missing one means the child did not finish, never success. The deadline
/// wins over anything but a `completed` result, which still counts when it
/// lands in the grace window. `launched` says a child process started: a
/// failure before that spent nothing, and any failure after it leaves the
/// child's spend unknown.
async fn result_file_outcome(
  path : String,
  id~ : String,
  timed_out~ : Bool,
  launched~ : Bool,
  runner_failure~ : String?,
  exit_code~ : Int?,
) -> ContractResult {
  fn outcome(
    terminal : ContractTerminal,
    report : Json?,
    usage : ChildUsage?,
    steps : Int?,
    unaccounted : String?,
  ) -> ContractResult {
    let (prompt, completion, cost_usd) = match usage {
      Some(usage) =>
        (usage.prompt_tokens, usage.completion_tokens, usage.cost_usd)
      None => (0, 0, None)
    }
    {
      report,
      terminal,
      steps_used: steps.unwrap_or(0),
      prompt_tokens: prompt,
      completion_tokens: completion,
      cost_usd,
      unaccounted,
      exit_code,
    }
  }
  // Without a usable result: the deadline, else the runner's own failure,
  // else the reason there is no result.
  fn no_result(reason : String, unaccounted : String) -> ContractResult {
    let terminal : ContractTerminal = match runner_failure {
      _ if timed_out => TimedOut
      Some(failure) => Failed(failure)
      None => Failed(reason)
    }
    outcome(terminal, None, None, None, Some(unaccounted))
  }
  guard launched else {
    let reason = runner_failure.unwrap_or("the child was not launched")
    return outcome(Failed(reason), None, None, None, None)
  }
  let exited = match exit_code {
    Some(code) => "exited \{code}"
    None => "did not exit in time"
  }
  let text = @fs.read_file(path).text() catch {
    @os_error.OSError(_) as error if error.is_ENOENT() =>
      return no_result(
        "the child \{exited} without writing a result",
        "the child left no result",
      )
    error =>
      return no_result(
        "the result file is unreadable: \{error}",
        "the result file is unreadable",
      )
  }
  let decoded = try @json.parse(text) catch {
    error => Err("not JSON: \{error}")
  } noraise {
    json => decode_result(json, id~)
  }
  guard decoded is Ok(result) else {
    let reason = match decoded {
      Err(reason) => reason
      Ok(_) => ""
    }
    return no_result(
      "malformed result file: \{reason}",
      "the result file is malformed",
    )
  }
  let unaccounted = match result.usage {
    Some(_) => None
    None => Some("the child's result carries no usage")
  }
  let reason = result.reason.unwrap_or(result.status)
  let terminal : ContractTerminal = match result.status {
    "completed" =>
      return outcome(
        Captured,
        result.output,
        result.usage,
        result.steps,
        unaccounted,
      )
    _ if timed_out => TimedOut
    "no_report" => NoReport
    "max_steps_exhausted" => MaxSteps
    "context_yield" => ContextYield
    "aborted" => Failed("aborted: \{reason}")
    "interrupted" => Failed("interrupted: \{reason}")
    _ => Failed(reason)
  }
  outcome(terminal, None, result.usage, result.steps, unaccounted)
}

///|
/// HOW one call becomes a process: the executable, its argv, and the
/// per-launch execution envelope. Everything a sandbox wrapper or a
/// deployment would want to rewrite lives HERE, in one immutable value —
/// never scattered across positional tuples.
///
/// A `launch` callback BUILDS one through `LaunchSpec(...)` and only this
/// package reads it, so the envelope can gain a knob without touching a
/// single engine adapter.
pub struct LaunchSpec {
  command : String
  args : Array[String]
  cwd : String?
  extra_env : Map[String, String]?
  deadline_ms : Int?
} derive(Eq)

///|
/// A launch from its parts: the executable and its argv, which every
/// launch names — and the argv must name `ResultFilePlaceholder`, where the
/// child writes its result. The execution envelope is optional — omit `cwd`
/// and `extra_env` to inherit the workflow's own, and `deadline_ms` to take
/// `contract_runner`'s.
pub fn LaunchSpec::LaunchSpec(
  command~ : String,
  args~ : Array[String],
  cwd? : String,
  extra_env? : Map[String, String],
  deadline_ms? : Int,
) -> LaunchSpec {
  { command, args, cwd, extra_env, deadline_ms, }
}

///|
/// The dot-callable form of the derived equality methods is a migration
/// convenience, not API: compare with `==` / `!=` (through the `Eq`
/// trait) instead.
#deprecated("Use == / != (the Eq trait) instead of the attached equal/not_equal method")
#doc(hidden)
pub extend LaunchSpec with Eq::{equal, not_equal}

///|
/// A `Runner` for ANY engine speaking the child contract: `launch` turns
/// each call into a `LaunchSpec`, the request carries the call's
/// kind/limits/input/schema, and every terminal maps into the lossless
/// `AgentOutcome` envelope. For engines whose reports are pure values
/// this is the whole adapter — an openseek-independent codex shim plugs
/// in right here. An engine whose reports name STATEFUL resources must
/// also pass `validate_replay`, or resumed journals can serve outcomes
/// whose referents no longer exist.
pub fn contract_runner(
  launch~ : (@workflow.AgentCall) -> LaunchSpec,
  deadline_ms? : Int = 600_000,
  validate_replay? : async (@workflow.AgentCall, @workflow.AgentOutcome) -> @workflow.ReplayDecision,
) -> @workflow.Runner {
  let ids : Ref[Int] = { val: 0, }
  @workflow.Runner(validate_replay?, call => {
    let spec = launch(call)
    ids.val += 1
    let id = "cr-\{ids.val}"
    let result = contract_run(
      command=spec.command,
      args=spec.args,
      input=call.input,
      kind=call.kind,
      id~,
      max_steps?=call.max_steps,
      schema?=call.schema,
      wall_deadline_ms=spec.deadline_ms.unwrap_or(deadline_ms),
      cwd?=spec.cwd,
      extra_env?=spec.extra_env,
    )
    let attempt = @workflow.AgentAttempt(
      attempt_id=id,
      steps_used=result.steps_used,
      prompt_tokens=result.prompt_tokens,
      completion_tokens=result.completion_tokens,
      cost_usd?=result.cost_usd,
      unaccounted?=result.unaccounted,
    )
    match result.terminal {
      Captured =>
        match result.report {
          Some(value) => Finished(value~, attempt~)
          None =>
            DidNotFinish(
              failure=Failed("captured terminal without a report"),
              attempt=Some(attempt),
            )
        }
      NoReport => DidNotFinish(failure=NoReport, attempt=Some(attempt))
      MaxSteps => DidNotFinish(failure=MaxSteps, attempt=Some(attempt))
      ContextYield => DidNotFinish(failure=ContextYield, attempt=Some(attempt))
      TimedOut => DidNotFinish(failure=TimedOut, attempt=Some(attempt))
      Failed(reason) =>
        DidNotFinish(failure=Failed(reason), attempt=Some(attempt))
    }
  })
}
