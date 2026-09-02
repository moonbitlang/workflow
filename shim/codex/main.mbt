///|
/// A PROCESS SHIM: Codex as a workflow engine. Speaks the child contract
/// on its own stdin/stdout (`docs/child-contract.md`) and drives
/// `codex exec --json` underneath, translating framing both ways. Build
/// it once, then point a `LaunchSpec` at the binary:
///
///   moon build shim/codex --target native
///   _build/native/release/build/shim/codex/codex.exe [--model m] [--cwd d] [--writable] [--schema f] [-- codex args...]
///
/// Kind policy: read-only runs (the default) use the `read-only` sandbox;
/// `worker`, or `--writable`, uses `workspace-write`. The request's
/// `max_steps` IS enforced here — each completed non-reasoning item is a
/// step, and the CLI is torn down the moment the ceiling is exceeded —
/// because the CLI has no turn cap of its own. Known limit (verified live
/// on codex-cli 0.151): Codex reports usage only on `turn.completed` and
/// does NOT flush it on SIGINT, so a capped run reports zero cost — the
/// parent sees `MaxSteps` with an honest zero, never an estimate.
async fn main {
  run() catch {
    error =>
      @shim.emit(@shim.command_error("codex shim failed: \{error}")) catch {
        _ => ()
      }
  }
}

///|
async fn run() -> Unit {
  let options = match
    @shim.Options::parse(@env.args()[1:], default_command="codex") {
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
  let state = Codex::new()
  let exit = @shim.run_cli(
    command=options.command,
    args=codex_args(request, options),
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
  let structured = options.schema is Some(_)
  match exit {
    Cancelled => ()
    Stopped => @shim.emit(@shim.max_steps_exhausted())
    Failed(reason) => @shim.emit(@shim.command_error(reason))
    Exited(code) =>
      if state.failure is Some(error) {
        @shim.emit(@shim.turn_failed(error))
      } else if state.report(structured~) is Some(report) {
        @shim.emit_report(report)
      } else if code != 0 {
        @shim.emit(@shim.turn_failed("codex exited \{code} without a message"))
      }
  }
}

///|
/// The CLI argv for one request: the prompt is the last positional. Codex
/// reads stdin as ADDITIONAL input even with a prompt on argv ("Reading
/// additional input from stdin…"), so the EOF `run_cli` puts on the CLI's
/// stdin is what keeps it from blocking.
fn codex_args(
  request : @shim.Request,
  options : @shim.Options,
) -> Array[String] {
  let sandbox = if options.writable || request.kind == "worker" {
    "workspace-write"
  } else {
    "read-only"
  }
  let args = ["exec", "--json", "--skip-git-repo-check", "-s", sandbox]
  if options.model is Some(model) {
    args.push("-m")
    args.push(model)
  }
  if options.schema is Some(path) {
    args.push("--output-schema")
    args.push(path)
  }
  args.push_iter(options.extra.iter())
  args.push(request.prompt)
  args
}

///|
test "argv: read-only sandbox by default, workspace-write for worker" {
  let request : @shim.Request = {
    id: None,
    kind: "explore",
    max_steps: None,
    input: Json::null(),
    prompt: "why?",
  }
  let options : @shim.Options = {
    command: "codex",
    model: Some("gpt-5"),
    cwd: None,
    writable: false,
    schema: Some("out.json"),
    extra: ["--ephemeral"],
  }
  assert_eq(codex_args(request, options), [
    "exec", "--json", "--skip-git-repo-check", "-s", "read-only", "-m", "gpt-5",
    "--output-schema", "out.json", "--ephemeral", "why?",
  ])
  let worker = { ..request, kind: "worker", }
  let plain = { ..options, model: None, schema: None, extra: [], }
  assert_eq(codex_args(worker, plain), [
    "exec", "--json", "--skip-git-repo-check", "-s", "workspace-write", "why?",
  ])
}
