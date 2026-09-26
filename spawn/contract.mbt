///|
/// THE CHILD CONTRACT, and its one implementation.
///
/// A workflow agent can be any process that speaks this wire contract:
///
/// - the runner writes ONE JSON line on the child's stdin and holds the
///   pipe open — closing it is the graceful-cancel signal, not the end
///   of input. The line is the VERSIONED request envelope
///   `{"workflow_contract": 1, "id": ..., "kind": ..., "max_steps"?: ...,
///   "schema"?: ..., "input": ...}` — self-contained, so the request never depends on
///   engine-specific argv (argv remains deployment configuration);
/// - the child emits JSONL on stdout: event lines (an object with an
///   `event` tag — `usage` and `agent_step` are summed/maxed for exact
///   cost accounting; `max_steps_exhausted`, `context_yield`,
///   `turn_failed`, `agent_setup_failed`, `command_error`, and
///   `agent_aborted` classify how a run degraded) and, last, ONE
///   distinguished `{"subrun_report": ...}` line carrying the result;
/// - non-JSON stdout lines are skipped (a leaky tool subprocess must not
///   poison the run);
/// - after `wall_deadline_ms` the runner closes stdin and grants
///   `cancel_grace_ms` to flush and exit — a report landing in the grace
///   window still counts — then terminates the child.
///
/// `openseek subrun <kind>` speaks this contract natively; a shim around
/// any other engine (a Rust CLI, a shell script) needs only to translate
/// framing. External cancellation of the CALLER is never folded into a
/// terminal: it re-raises after teardown, per structured concurrency.
let default_cancel_grace_ms : Int = 5_000

///|
/// How a child hands back its result. The launch configuration chooses it;
/// the runner never guesses a transport from what the child prints.
pub(all) enum Transport {
  /// Contract transport 1: JSONL events on stdout and a final
  /// `{"subrun_report": ...}` line, as described above.
  StdoutEvents
  /// Contract transport 2: the child writes ONE result file, whose path the
  /// runner substitutes for `{result_file}` in the argv, and its stdout is
  /// drained but never read — it is for humans. See docs/child-contract.md.
  ResultFile
} derive(Eq)

///|
/// The dot-callable form of the derived equality methods is a migration
/// convenience, not API: compare with `==` / `!=` (through the `Eq`
/// trait) instead.
#deprecated("Use == / != (the Eq trait) instead of the attached equal/not_equal method")
#doc(hidden)
pub extend Transport with Eq::{equal, not_equal}

///|
/// The argv placeholder the runner replaces with the result file's path under
/// `ResultFile`. An argv that carries it under `StdoutEvents` (or lacks it
/// under `ResultFile`) is a launch error, reported as `Failed`.
pub const ResultFilePlaceholder : String = "{result_file}"

///|
/// How a contract run ended. `Captured` means a report line arrived —
/// whether its CONTENT is acceptable is the caller's judgment, at the
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
/// One contract run's outcome: the RAW report (when one arrived) plus the
/// cost observed from the child's own event stream.
pub struct ContractResult {
  report : Json?
  terminal : ContractTerminal
  steps_used : Int
  prompt_tokens : Int
  completion_tokens : Int
  /// Summed `usage.cost_usd` across usage lines that carried a valid
  /// price; `None` until one is charged — a present-but-invalid price
  /// voids the whole line, so it does not count as carried.
  cost_usd : Double?
  /// Why the counters above may fall short of what the child spent: `Some`
  /// when a `ResultFile` child left no usable result (it crashed, was
  /// killed, or its file was malformed), or its result carried no usage.
  /// `None` means the counters are the child's own account.
  unaccounted : String?
  /// The child's exit status, when it exited within the runner's watch.
  /// Kept beside a result, so an abnormal exit after a valid result stays
  /// visible instead of being masked by it.
  exit_code : Int?
}

///|
priv struct Observations {
  /// `false` under `ResultFile`: stdout is then drained unread, so nothing
  /// a child (or a leaky tool) prints can pose as a result.
  interpret : Bool
  progress : ContractProgress
  observe_line : ((Json) -> Unit)?
  mut max_steps_exhausted : Bool
  mut context_yield : Bool
  mut failure : String?
  mut report : Json?
}

///|
/// Classify one child stdout line, structurally — the tags are the wire
/// contract, not any engine's type vocabulary.
fn Observations::observe(self : Observations, line : String) -> Unit {
  guard self.interpret else { return }
  let trimmed = line.trim(chars="\r\n")
  if trimmed == "" {
    return
  }
  let json = @json.parse(trimmed) catch { _ => return }
  if self.observe_line is Some(hook) {
    hook(json)
  }
  if json is { "subrun_report": report, .. } {
    self.report = Some(report)
    return
  }
  match json {
    { "event": "agent_step", "step": Number(step, ..), .. } =>
      if integral(step) is Some(step) {
        self.progress.steps = self.progress.steps.max(step)
      }
    {
      "event": "usage",
      "usage": {
        "prompt_tokens": Number(prompt, ..),
        "completion_tokens": Number(completion, ..),
        "total_tokens": Number(total, ..),
        "prompt_cache_hit_tokens": Number(cache_hit, ..),
        "prompt_cache_miss_tokens": Number(cache_miss, ..),
        ..
      },
      ..
    } => {
      // Integral-only and whole-object, exactly as the engine's typed
      // decoder: a counter of 1.5 is not a token count, and a malformed
      // usage line is ignored WHOLE — never partially charged.
      // Money is optional and fractional by nature — the integral rule
      // covers token counts, not prices — but a PRESENT price that is not a
      // non-negative number is as malformed as a bad token field, and the
      // whole line is ignored rather than charged in part.
      let price : Double? = match json {
        { "usage": { "cost_usd": Number(cost, ..), .. }, .. } if cost >= 0.0 &&
          !cost.is_inf() &&
          !cost.is_nan() => Some(cost)
        { "usage": { "cost_usd": _, .. }, .. } => return
        _ => None
      }
      if integral(prompt) is Some(prompt) &&
        integral(completion) is Some(completion) &&
        integral(total) is Some(_) &&
        integral(cache_hit) is Some(_) &&
        integral(cache_miss) is Some(_) {
        self.progress.prompt_tokens += prompt
        self.progress.completion_tokens += completion
        if price is Some(cost) {
          self.progress.cost_usd = Some(
            self.progress.cost_usd.unwrap_or(0.0) + cost,
          )
        }
      }
    }
    { "event": "max_steps_exhausted", .. } => self.max_steps_exhausted = true
    {
      "event": "context_yield",
      "to_sequence": Number(to_sequence, ..),
      "answer": String(_),
      ..
    } => if integral(to_sequence) is Some(_) { self.context_yield = true }
    { "event": "turn_failed", "error": String(error), .. }
    | { "event": "agent_setup_failed", "error": String(error), .. }
    | { "event": "command_error", "error": String(error), .. }
    | { "event": "agent_aborted", "reason": String(error), .. } =>
      self.failure = Some(error)
    _ => ()
  }
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
/// Run one child over the contract: spawn, feed the input line, drain and
/// account the event stream, enforce the wall deadline with its grace
/// window, and tear the child down on every path. Crash isolation is
/// structural: a dead or unspawnable child is a `Failed` terminal, never
/// a dead caller. External cancellation re-raises after teardown.
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
  progress? : ContractProgress,
  observe_line? : (Json) -> Unit,
  transport? : Transport = StdoutEvents,
) -> ContractResult {
  let progress = match progress {
    Some(progress) => progress
    None => ContractProgress()
  }
  // The launch configuration and the transport must agree: a placeholder
  // passed through literally, or a result nobody was told where to write,
  // would each fail in a way that looks like the child's fault.
  let names_result_file = args.any(arg => arg.contains(ResultFilePlaceholder))
  let result_dir = match (transport, names_result_file) {
    (StdoutEvents, false) => None
    (StdoutEvents, true) =>
      return launch_failed(
        progress,
        "the argv names \{ResultFilePlaceholder}, but the transport is StdoutEvents",
      )
    (ResultFile, false) =>
      return launch_failed(
        progress,
        "the ResultFile transport needs \{ResultFilePlaceholder} in the argv",
      )
    (ResultFile, true) =>
      Some(
        @fs.tmpdir(prefix="workflow-result-") catch {
          error =>
            return launch_failed(
              progress,
              "no directory for the result file: \{error}",
            )
        },
      )
  }
  // A private directory per launch, so no other process can have left a file
  // at the path, and nothing of this one outlives the call.
  defer (if result_dir is Some(dir) {
    @fs.rmdir(dir, recursive=true) catch {
      _ => ()
    }
  })
  let result_path = result_dir.map(dir => "\{dir}/result.json")
  let args = match result_path {
    Some(path) =>
      args.map(arg => arg.replace_all(old=ResultFilePlaceholder, new=path))
    None => args
  }
  let mut exit_code : Int? = None
  let observations : Observations = {
    interpret: transport is StdoutEvents,
    progress,
    observe_line,
    max_steps_exhausted: false,
    context_yield: false,
    failure: None,
    report: None,
  }
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
          observations.failure = Some("subrun pipes unavailable: \{error}")
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
          observations.failure = Some("subrun pipes unavailable: \{error}")
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
          observations.failure = Some("subrun spawn failed: \{error}")
          return
        }
      }
      defer process.cancel()
      async fn drain() -> Unit {
        while stdout_reader.read_until("\n") is Some(line) {
          observations.observe(line)
        }
      }
      async fn feed_and_drain() -> Unit {
        // One input line — the v1 request envelope; the pipe stays open,
        // EOF is the cancel signal, not the end of input. The write sits
        // INSIDE the deadline scope: an input larger than the pipe
        // capacity against a child that never reads must hit the wall
        // deadline, not block forever.
        let request = request_line(
          transport,
          id~,
          kind~,
          input~,
          max_steps?,
          schema?,
        )
        stdin_writer.write("\{request.stringify()}\n")
        drain()
      }
      try {
        match @async.with_timeout_opt(wall_deadline_ms, feed_and_drain) {
          Some(_) =>
            // Clean EOF: the child closed stdout. Read its exit status — a
            // crash-class failure (panic, signal, nonzero exit) emits no
            // failure event, and without this the runner is structurally
            // blind to it and would misclassify the run as NoReport.
            // Bounded: a child that closed stdout but lingers falls
            // through to the cancel below.
            match @async.with_timeout_opt(2_000, () => process.wait()) {
              Some(code) => {
                exit_code = Some(code)
                if transport is StdoutEvents &&
                  code != 0 &&
                  observations.report is None &&
                  observations.failure is None {
                  observations.failure = Some("subrun exited \{code}")
                }
              }
              None => ()
            }
          None => {
            // Deadline: graceful cancel first — close stdin, let the child
            // flush; a report arriving in the grace window still counts.
            timed_out = true
            stdin_writer.close()
            let _ = @async.with_timeout_opt(cancel_grace_ms, drain)
          }
        }
      } catch {
        error => {
          // A pipe failure: the deferred teardown stops the child; fold the
          // error into the terminal. Cancellation never reaches a `catch`;
          // it unwinds through the defers above.
          if observations.failure is None {
            observations.failure = Some("subrun stream failed: \{error}")
          }
          return
        }
      }
    }
  catch {
    error =>
      if observations.failure is None {
        observations.failure = Some("subrun runner failed: \{error}")
      }
  }
  if result_path is Some(path) {
    return result_file_outcome(
      path,
      id~,
      timed_out~,
      launch_failure=observations.failure,
      exit_code~,
    )
  }
  let terminal = match observations.report {
    Some(_) => Captured
    None =>
      match observations.failure {
        Some(error) => Failed(error)
        None if timed_out => TimedOut
        None if observations.max_steps_exhausted => MaxSteps
        None if observations.context_yield => ContextYield
        None => NoReport
      }
  }
  {
    report: observations.report,
    terminal,
    steps_used: progress.steps,
    prompt_tokens: progress.prompt_tokens,
    completion_tokens: progress.completion_tokens,
    cost_usd: progress.cost_usd,
    unaccounted: None,
    exit_code,
  }
}

///|
/// A run that failed before a child was launched: nothing was spent.
fn launch_failed(
  progress : ContractProgress,
  reason : String,
) -> ContractResult {
  {
    report: None,
    terminal: Failed(reason),
    steps_used: progress.steps,
    prompt_tokens: progress.prompt_tokens,
    completion_tokens: progress.completion_tokens,
    cost_usd: progress.cost_usd,
    unaccounted: None,
    exit_code: None,
  }
}

///|
/// The one request line for `transport`. Transport 1 writes the
/// `workflow_contract: 1` envelope. Transport 2 writes the request document
/// (`version: 1`) whose `request_id` the child echoes in its result; `schema`
/// rides along only when the caller passed one, and an engine that cannot
/// honour it must refuse the request rather than ignore it.
fn request_line(
  transport : Transport,
  id~ : String,
  kind~ : String,
  input~ : Json,
  max_steps? : Int,
  schema? : Json,
) -> Json {
  let fields : Map[String, Json] = match transport {
    StdoutEvents =>
      {
        "workflow_contract": 1,
        "id": Json(id),
        "kind": Json(kind),
        "input": input,
      }
    ResultFile =>
      {
        "version": 1,
        "request_id": Json(id),
        "kind": Json(kind),
        "input": input,
      }
  }
  match (transport, max_steps) {
    (_, None) => ()
    (StdoutEvents, Some(steps)) => fields["max_steps"] = Json(steps)
    (ResultFile, Some(steps)) => fields["limits"] = { "max_steps": Json(steps) }
  }
  if schema is Some(schema) {
    fields["schema"] = schema
  }
  Json::object(fields)
}

///|
/// A transport-2 child's result, as far as this runner reads it.
priv struct ChildResult {
  status : String
  output : Json?
  reason : String?
  /// `(steps, prompt_tokens, completion_tokens)`, when the result carried
  /// usage.
  counters : (Int, Int, Int)?
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
  // Usage is whole or absent: a partial or fractional counter voids it, as
  // on the event stream.
  let counters = match (fields.get("usage"), fields.get("steps")) {
    (None, _) => None
    (
      Some(
        {
          "prompt_tokens": Number(prompt, ..),
          "completion_tokens": Number(completion, ..),
          "total_tokens": Number(total, ..),
          "prompt_cache_hit_tokens": Number(hit, ..),
          "prompt_cache_miss_tokens": Number(miss, ..),
          ..
        }
      ),
      steps,
    ) =>
      match
        (
          integral(prompt),
          integral(completion),
          integral(total),
          integral(hit),
          integral(miss),
          steps,
        ) {
        (Some(prompt), Some(completion), Some(_), Some(_), Some(_), None) if prompt >=
          0 &&
          completion >= 0 => Some((0, prompt, completion))
        (
          Some(prompt),
          Some(completion),
          Some(_),
          Some(_),
          Some(_),
          Some(Number(steps, ..)),
        ) if prompt >= 0 && completion >= 0 =>
          match integral(steps) {
            Some(steps) if steps >= 0 => Some((steps, prompt, completion))
            _ => return Err("malformed steps")
          }
        _ => return Err("malformed usage")
      }
    (Some(_), _) => return Err("malformed usage")
  }
  Ok({ status, output: fields.get("output"), reason, counters, })
}

///|
/// Classify a transport-2 run from its result file. The file is authoritative:
/// a missing one means the child did not finish, never success. A child that
/// was cut off at the deadline is `TimedOut` unless it completed within the
/// grace window.
async fn result_file_outcome(
  path : String,
  id~ : String,
  timed_out~ : Bool,
  launch_failure~ : String?,
  exit_code~ : Int?,
) -> ContractResult {
  fn outcome(
    terminal : ContractTerminal,
    report : Json?,
    counters : (Int, Int, Int)?,
    unaccounted : String?,
  ) -> ContractResult {
    let (steps, prompt, completion) = counters.unwrap_or((0, 0, 0))
    {
      report,
      terminal,
      steps_used: steps,
      prompt_tokens: prompt,
      completion_tokens: completion,
      cost_usd: None,
      unaccounted,
      exit_code,
    }
  }
  let exited = match exit_code {
    Some(code) => "exited \{code}"
    None => "did not exit in time"
  }
  let text = @fs.read_file(path).text() catch {
    @os_error.OSError(_) as error if error.is_ENOENT() => {
      let terminal : ContractTerminal = match launch_failure {
        Some(reason) => Failed(reason)
        None if timed_out => TimedOut
        None => Failed("the child \{exited} without writing a result")
      }
      // A launch that never started spent nothing; any other child may have.
      let unaccounted = match launch_failure {
        Some(_) => None
        None => Some("the child left no result")
      }
      return outcome(terminal, None, None, unaccounted)
    }
    error =>
      return outcome(
        Failed("the result file is unreadable: \{error}"),
        None,
        None,
        Some("the result file is unreadable"),
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
    return outcome(
      Failed("malformed result file: \{reason}"),
      None,
      None,
      Some("the result file is malformed"),
    )
  }
  let unaccounted = match result.counters {
    Some(_) => None
    None => Some("the child's result carries no usage")
  }
  let reason = result.reason.unwrap_or(result.status)
  let terminal : ContractTerminal = match result.status {
    "completed" =>
      return outcome(Captured, result.output, result.counters, unaccounted)
    _ if timed_out => TimedOut
    "no_report" => NoReport
    "max_steps_exhausted" => MaxSteps
    "context_yield" => ContextYield
    "aborted" => Failed("aborted: \{reason}")
    "interrupted" => Failed("interrupted: \{reason}")
    _ => Failed(reason)
  }
  outcome(terminal, None, result.counters, unaccounted)
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
  /// How the child hands back its result; see `Transport`.
  transport : Transport
} derive(Eq)

///|
/// A launch from its parts: the executable and its argv, which every
/// launch names. The execution envelope is optional — omit `cwd` and
/// `extra_env` to inherit the workflow's own, and `deadline_ms` to take
/// `contract_runner`'s. `transport` defaults to the event stream; a
/// `ResultFile` launch names `{result_file}` in its argv.
pub fn LaunchSpec::LaunchSpec(
  command~ : String,
  args~ : Array[String],
  cwd? : String,
  extra_env? : Map[String, String],
  deadline_ms? : Int,
  transport? : Transport = StdoutEvents,
) -> LaunchSpec {
  { command, args, cwd, extra_env, deadline_ms, transport, }
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
/// each call into a `LaunchSpec`, the request envelope carries the
/// call's kind/limits/input, and every terminal maps into the lossless
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
      transport=spec.transport,
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
