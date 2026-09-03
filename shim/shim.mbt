///|
/// THE SHIM SIDE OF THE CHILD CONTRACT — what every process shim around a
/// foreign agent CLI needs: parse the one request line the runner writes,
/// keep the parent's stdin-EOF cancel signal live while the CLI runs,
/// speak the contract's event vocabulary on stdout, and print the report
/// line last. `shim/claude` and `shim/codex` are the two dialects; this
/// package knows no CLI.
///
/// One request as the runner sent it (`docs/child-contract.md` §2), or a
/// bare input line for hand-driven runs. `prompt` is derived from `input`
/// the way `Workflow::agent` builds it: a `query` plus optional `hints`.
pub(all) struct Request {
  id : String?
  kind : String
  max_steps : Int?
  input : Json
  prompt : String
  /// The JSON Schema the report must satisfy, when the call asked for one
  /// (envelope `schema`); the shims hand it to the CLI's structured-output
  /// flag, and it takes precedence over a `--schema` file on argv.
  schema : Json?
}

///|
/// Decode one stdin line. Accepts the v1 envelope (rejecting any other
/// major loudly) or a bare input. The input must yield a prompt: a
/// `query` string with optional `hints`, a `prompt` string, or a bare
/// string — anything else is a typed refusal the caller turns into a
/// `command_error`.
pub fn Request::parse(line : String) -> Result[Request, String] {
  let trimmed = line.trim(chars="\r\n")
  guard (Some(@json.parse(trimmed.to_owned())) catch { _ => None })
    is Some(json) else {
    return Err("shim input is not JSON")
  }
  let (id, kind, max_steps, input, schema) = match json {
    { "workflow_contract": Number(1, ..), "input": input, .. } => {
      let id = if json is { "id": String(id), .. } { Some(id) } else { None }
      let kind = if json is { "kind": String(kind), .. } {
        kind
      } else {
        "explore"
      }
      // A present-but-wrong ceiling (a string, null, 5.5) is a malformed
      // request, never "no ceiling" (cross-engine review findings).
      let max_steps = match json {
        { "max_steps": Number(steps, ..), .. } =>
          match integral(steps) {
            Some(steps) => Some(steps)
            None => return Err("shim input max_steps must be an integer")
          }
        { "max_steps": _, .. } =>
          return Err("shim input max_steps must be an integer")
        _ => None
      }
      // A schema is a JSON object (contract §2); null means none; anything
      // else is a malformed request, refused here rather than by the CLI.
      let schema = match json {
        { "schema": Object(_) as schema, .. } => Some(schema)
        { "schema": Null, .. } => None
        { "schema": _, .. } =>
          return Err("shim input schema must be a JSON object")
        _ => None
      }
      (id, kind, max_steps, input, schema)
    }
    // A v1 envelope without its payload is malformed, not an unsupported
    // version (cross-engine review finding).
    { "workflow_contract": Number(1, ..), .. } =>
      return Err("shim input envelope has no `input`")
    { "workflow_contract": Number(version, ..), .. } =>
      return Err("unsupported workflow_contract version \{version}")
    other => (None, "explore", None, other, None)
  }
  guard prompt_of(input) is Some(prompt) else {
    return Err("shim input needs a `query` (or `prompt`) string")
  }
  Ok({ id, kind, max_steps, input, prompt, schema, })
}

///|
fn prompt_of(input : Json) -> String? {
  match input {
    String(text) if !text.is_blank() => Some(text)
    { "query": String(query), "hints": String(hints), .. } if !query.is_blank() &&
      !hints.is_blank() => Some("\{query}\n\nHints: \{hints}")
    { "query": String(query), .. } if !query.is_blank() => Some(query)
    { "prompt": String(prompt), .. } if !prompt.is_blank() => Some(prompt)
    _ => None
  }
}

///|
/// Read the request line from stdin. `None` means EOF before any input —
/// the parent gave up before we started; exit silently. The pipe stays
/// open afterwards as the cancel channel, which `run_cli` watches.
pub async fn read_request() -> Result[Request, String]? {
  guard @stdio.stdin.read_until("\n") is Some(line) else { return None }
  Some(Request::parse(line))
}

///|
/// Write one event line. Everything the runner classifies on goes through
/// here, in order, before the report.
pub async fn emit(event : Json) -> Unit {
  @stdio.stdout.write("\{event.stringify()}\n")
}

///|
/// The final line, `{"subrun_report": report}` — call it after every
/// event, never before.
pub async fn emit_report(report : Json) -> Unit {
  let line : Json = { "subrun_report": report }
  emit(line)
}

///|
/// An `agent_step` event; the runner keeps the maximum step it sees.
pub fn agent_step(step : Int) -> Json {
  { "event": "agent_step", "step": step }
}

///|
/// A `usage` event with every field the runner requires (§3): a partial
/// usage line is ignored whole, so the five counters are always emitted
/// together. `total_tokens` is derived.
pub fn usage(
  prompt_tokens~ : Int,
  completion_tokens~ : Int,
  cache_hit~ : Int,
  cache_miss~ : Int,
  cost_usd? : Double,
) -> Json {
  let event : Json = {
    "event": "usage",
    "usage": {
      "prompt_tokens": prompt_tokens,
      "completion_tokens": completion_tokens,
      "total_tokens": prompt_tokens + completion_tokens,
      "prompt_cache_hit_tokens": cache_hit,
      "prompt_cache_miss_tokens": cache_miss,
    },
  }
  // The engine's own price, when it states one (`usage.cost_usd` on the
  // wire): the runner sums it into the attempt.
  if cost_usd is Some(cost) && event is { "usage": Object(fields), .. } {
    fields["cost_usd"] = cost.to_json()
  }
  event
}

///|
/// A `turn_failed` event: the run degraded and there will be no report.
pub fn turn_failed(error : String) -> Json {
  { "event": "turn_failed", "error": error }
}

///|
/// A `command_error` event: the request or the shim's own argv was wrong.
pub fn command_error(error : String) -> Json {
  { "event": "command_error", "error": error }
}

///|
/// A `max_steps_exhausted` event: the step ceiling stopped the run.
pub fn max_steps_exhausted() -> Json {
  { "event": "max_steps_exhausted" }
}

///|
/// JSON has one number type; an `Int` counter arrives as a `Number`.
/// Reject a fractional value rather than truncating it.
pub fn integral(value : Double) -> Int? {
  let rounded = value.to_int()
  if rounded.to_double() == value {
    Some(rounded)
  } else {
    None
  }
}

///|
/// What the observer decides after each CLI stdout line.
pub(all) enum Verdict {
  Continue
  Stop
} derive(Eq)

///|
pub extend Verdict with Eq::{equal, not_equal}

///|
/// How a CLI run ended, from the shim's side. `Cancelled` is the parent's
/// stdin EOF: exit without a report, the parent is already classifying.
/// `Stopped` is the observer's own decision (a step ceiling). `Failed` is
/// a run that never got going — an unspawnable command, a broken pipe.
pub enum CliExit {
  Exited(Int)
  Stopped
  Cancelled
  Failed(String)
} derive(Eq)

///|
pub extend CliExit with Eq::{equal, not_equal}

///|
/// Run the CLI: spawn it with its stdin already at EOF (the prompt rides
/// argv; OUR stdin is the parent's cancel channel and is never the
/// CLI's), hand every stdout line to `observe`, and tear the CLI down when
/// the observer says `Stop` or the parent closes our stdin. stderr is
/// inherited, so the CLI's diagnostics reach the parent's stderr
/// untouched.
///
/// A `Stop` is GRACEFUL: the CLI gets `stop_signal` (SIGINT, its own Ctrl-C
/// path) and `stop_grace_ms` to flush,
/// and every line it prints meanwhile still reaches `observe` — a CLI
/// that reports usage only at the end of a turn (Codex) can still get its
/// cost recorded on a capped run. Then it is killed. Every error path —
/// an observer that raises, a broken pipe, the caller's cancellation —
/// closes the pipes and terminates the CLI before returning or
/// re-raising; the task group would reap it anyway, but not before the
/// caller had already been told. `watch_stdin=false` is for tests, whose
/// stdin is not a parent's pipe.
pub async fn run_cli(
  command~ : String,
  args~ : Array[String],
  cwd? : String,
  watch_stdin? : Bool = true,
  stop_grace_ms? : Int = 3_000,
  stop_signal? : @signal.Signal = @signal.SIGINT,
  observe~ : async (String) -> Verdict,
) -> CliExit {
  let cancelled : Ref[Bool] = { val: false, }
  let stopped : Ref[Bool] = { val: false, }
  let code : Ref[Int] = { val: 0, }
  let failure : Ref[String?] = { val: None, }
  try
    @async.with_task_group() <| group => {
      let (child_stdin, stdin_writer) = @process.write_to_process() catch {
        error if @async.is_being_cancelled() => raise error
        error => {
          failure.val = Some("shim pipes unavailable: \{error}")
          return
        }
      }
      let (stdout_reader, child_stdout) = @process.read_from_process() catch {
        error if @async.is_being_cancelled() => {
          stdin_writer.close()
          raise error
        }
        error => {
          stdin_writer.close()
          failure.val = Some("shim pipes unavailable: \{error}")
          return
        }
      }
      let process = @process.spawn(
        group,
        command,
        args,
        inherit_env=true,
        stdin=child_stdin,
        stdout=child_stdout,
        cwd?=cwd.map(dir => dir.view()),
        // `cancel()` sends SIGINT first — the CLI's own Ctrl-C path, the
        // one it flushes on — and kills only after the grace.
        cancel_handler=@process.graceful_cancel(
          timeout=stop_grace_ms,
          signal=stop_signal,
        ),
        no_wait=true,
      ) catch {
        error if @async.is_being_cancelled() => {
          stdout_reader.close()
          stdin_writer.close()
          raise error
        }
        error => {
          stdout_reader.close()
          stdin_writer.close()
          failure.val = Some("cannot spawn \{command}: \{error}")
          return
        }
      }
      // EOF at once: the CLI must never wait on stdin for a prompt.
      stdin_writer.close()
      if watch_stdin {
        group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
          while @stdio.stdin.read_until("\n") is Some(_) {
            // Only EOF is meaningful.
          }
          cancelled.val = true
          process.cancel()
        }
      }
      fn teardown() -> Unit {
        stdout_reader.close()
        process.cancel()
      }
      try {
        while stdout_reader.read_until("\n") is Some(line) {
          if cancelled.val {
            break
          }
          if observe(line) is Stop {
            stopped.val = true
            // Graceful: SIGINT now, keep listening through the grace so a
            // final accounting line still counts, then the handler kills.
            process.cancel()
            let _ = @async.with_timeout_opt(stop_grace_ms, () => {
              while stdout_reader.read_until("\n") is Some(late) {
                let _ = observe(late)
              }
            })
            break
          }
        }
        if !cancelled.val && !stopped.val {
          // Bounded: a CLI that closed stdout but lingers is torn down below.
          code.val = @async.with_timeout_opt(2_000, () => process.wait()).unwrap_or(
            -1,
          )
        }
      } catch {
        error => {
          @async.protect_from_cancel(() => teardown())
          if @async.is_being_cancelled() {
            raise error
          }
          if failure.val is None {
            failure.val = Some("shim run failed: \{error}")
          }
          return
        }
      }
      teardown()
    }
  catch {
    error if @async.is_being_cancelled() || @async.is_cancellation_error(error) =>
      raise error
    error =>
      if failure.val is None {
        failure.val = Some("shim run failed: \{error}")
      }
  }
  match failure.val {
    Some(reason) => Failed(reason)
    None if cancelled.val => Cancelled
    None if stopped.val => Stopped
    None => Exited(code.val)
  }
}
