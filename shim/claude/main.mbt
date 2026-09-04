///|
/// A PROCESS SHIM: Claude Code as a workflow engine. Speaks the child
/// contract on its own stdin/stdout (`docs/child-contract.md`) and drives
/// `claude -p --output-format stream-json` underneath, translating
/// framing both ways. Point a `LaunchSpec` at the PUBLISHED shim — no
/// build step, no path to hard-code:
///
///   moonx moonbitlang/workflow/shim/claude [--model m] [--cwd d] [--writable] [--schema f] [-- claude args...]
///
/// `moonx` runs the wasm build, which this shim fully supports: it spawns
/// the CLI, keeps the parent's stdin-EOF cancel channel live, and frames
/// stdout exactly as the native build does. Building locally
/// (`just shims`) is for developing THIS shim, where the published
/// version is not what you want to run.
///
/// Kind policy: read-only runs (the default) disallow the editing and
/// shell tools; `worker`, or `--writable`, accepts edits and allows them.
/// The request's `max_steps` IS enforced here — each `assistant` message
/// is a step, and the CLI is torn down the moment the ceiling is
/// exceeded — because the CLI has no turn cap of its own.
async fn main {
  run() catch {
    error =>
      @shim.emit(@shim.command_error("claude shim failed: \{error}")) catch {
        _ => ()
      }
  }
}

///|
async fn run() -> Unit {
  let options = match
    @shim.Options::parse(@env.args()[1:], default_command="claude") {
    Ok(options) => options
    Err(problem) => {
      @shim.emit(@shim.command_error(problem))
      return
    }
  }
  guard @shim.read_request() is Some(parsed) else { return }
  let request = match parsed {
    Ok(request) => request
    Err(problem) => {
      @shim.emit(@shim.command_error(problem))
      return
    }
  }
  // The call's own schema (envelope) wins; `--schema <file>` is the
  // deployment default for scripts that pass none.
  let schema = match (envelope_schema(request), options.schema) {
    (Some(schema), _) => Some(schema)
    (None, Some(path)) =>
      Some(@utf8.decode_lossy(@fs.read_file(path).binary())) catch {
        error => {
          @shim.emit(
            @shim.command_error("cannot read --schema \{path}: \{error}"),
          )
          return
        }
      }
    (None, None) => None
  }
  let state = Claude()
  let exit = @shim.run_cli(
    command=options.command,
    args=claude_args(request, options, schema),
    cwd?=options.cwd,
    observe=line => {
      // Emit first, then judge the ceiling: the over-limit step DID happen
      // (the CLI already made the call), so its step and cost are reported
      // before the run is stopped — steps and charges stay consistent.
      for event in state.observe(line) {
        @shim.emit(event)
      }
      if request.max_steps is Some(limit) && state.steps > limit {
        return @shim.Stop
      }
      @shim.Continue
    },
  )
  // A run that ended without its result never charged the true totals:
  // settle the per-message snapshots first, so the cost of the work done
  // still reaches the parent before the terminal event.
  if !(exit is Failed(_)) && state.settle() is Some(usage) {
    @shim.emit(usage)
  }
  match exit {
    Cancelled => ()
    Stopped => @shim.emit(@shim.max_steps_exhausted())
    Failed(reason) => @shim.emit(@shim.command_error(reason))
    Exited(code) =>
      if state.failure is Some(error) {
        @shim.emit(@shim.turn_failed(error))
      } else if state.exhausted {
        @shim.emit(@shim.max_steps_exhausted())
      } else if state.report() is Some(report) {
        @shim.emit_report(report)
      } else if code != 0 {
        @shim.emit(@shim.turn_failed("claude exited \{code} without a result"))
      }
  }
}

///|
/// The CLI argv for one request. The prompt is the first positional so
/// the variadic tool lists can sit last without swallowing anything;
/// pass-through args go before them for the same reason.
fn claude_args(
  request : @shim.Request,
  options : @shim.Options,
  schema : String?,
) -> Array[String] {
  let args = [
    "-p",
    request.prompt,
    "--output-format",
    "stream-json",
    "--verbose",
  ]
  if options.model is Some(model) {
    args.push("--model")
    args.push(model)
  }
  if schema is Some(schema) {
    args.push("--json-schema")
    args.push(schema)
  }
  args.push_iter(options.extra.iter())
  let mutating = ["Edit", "Write", "MultiEdit", "NotebookEdit", "Bash"]
  if options.writable || request.kind == "worker" {
    args.push("--permission-mode")
    args.push("acceptEdits")
    args.push("--allowedTools")
    args.push_iter(mutating.iter())
  } else {
    args.push("--disallowedTools")
    args.push_iter(mutating.iter())
  }
  args
}

///|
test "argv: read-only by default, writable for worker, extras before the tool list" {
  let request : @shim.Request = {
    id: None,
    kind: "explore",
    max_steps: None,
    input: Json::null(),
    prompt: "why?",
    schema: None,
  }
  let options : @shim.Options = {
    command: "claude",
    model: Some("opus"),
    cwd: None,
    writable: false,
    schema: None,
    extra: ["--max-budget-usd", "1"],
  }
  assert_eq(claude_args(request, options, None), [
    "-p", "why?", "--output-format", "stream-json", "--verbose", "--model", "opus",
    "--max-budget-usd", "1", "--disallowedTools", "Edit", "Write", "MultiEdit", "NotebookEdit",
    "Bash",
  ])
  let worker = { ..request, kind: "worker", }
  let plain = { ..options, model: None, extra: [], }
  assert_eq(claude_args(worker, plain, Some("{}")), [
    "-p", "why?", "--output-format", "stream-json", "--verbose", "--json-schema",
    "{}", "--permission-mode", "acceptEdits", "--allowedTools", "Edit", "Write",
    "MultiEdit", "NotebookEdit", "Bash",
  ])
}

///|
/// The envelope's schema as the inline JSON text `--json-schema` takes.
fn envelope_schema(request : @shim.Request) -> String? {
  request.schema.map(schema => schema.stringify())
}

///|
test "the envelope's schema becomes the inline --json-schema text" {
  let request : @shim.Request = {
    id: None,
    kind: "explore",
    max_steps: None,
    input: Json::null(),
    prompt: "why?",
    schema: Some({ "type": "object" }),
  }
  assert_eq(envelope_schema(request), Some("{\"type\":\"object\"}"))
  assert_eq(envelope_schema({ ..request, schema: None, }), None)
}
