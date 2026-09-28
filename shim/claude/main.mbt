///|
/// A PROCESS SHIM: Claude Code as a workflow engine. Speaks the child
/// contract (`docs/child-contract.md`): one request line
/// on stdin, one result file at `--result-file`. It drives
/// `claude -p --output-format stream-json` underneath and reads that stream
/// for the answer, the usage, and the steps. Point a `LaunchSpec` at the
/// PUBLISHED shim — no build step, no path to hard-code:
///
///   moonx moonbitlang/workflow/shim/claude --result-file {result_file} [--model m] [--cwd d] [--writable] [--schema f] [-- claude args...]
///
/// The runner substitutes a fresh path for `{result_file}`. `moonx` runs the wasm build, which this shim fully
/// supports: it spawns the CLI, keeps the parent's stdin-EOF cancel channel
/// live, and writes the result exactly as the native build does. Building
/// locally (`just shims`) is for developing THIS shim, where the published
/// version is not what you want to run.
///
/// Kind policy: read-only runs (the default) disallow the editing and
/// shell tools; `worker`, or `--writable`, accepts edits and allows them.
/// The request's `limits.max_steps` IS enforced here — each `assistant`
/// message is a step, and the CLI is torn down the moment the ceiling is
/// exceeded — because the CLI has no turn cap of its own.
async fn main {
  @shim.serve(default_command="claude", run~)
}

///|
/// One request, start to finish: the result file's content.
async fn run(
  options : @shim.Options,
  request : @shim.Request,
) -> @shim.ShimResult {
  // The call's own schema (request) wins; `--schema <file>` is the
  // deployment default for scripts that pass none.
  let schema = match (request_schema(request), options.schema) {
    (Some(schema), _) => Some(schema)
    (None, Some(path)) =>
      Some(@utf8.decode_lossy(@fs.read_file(path).binary())) catch {
        error =>
          return @shim.ShimResult(
            Failed("cannot read --schema \{path}: \{error}"),
          )
      }
    (None, None) => None
  }
  let state = Claude()
  let exit = @shim.run_cli(
    command=options.command,
    args=claude_args(request, options, schema),
    cwd?=options.cwd,
    observe=line => {
      // Count first, then judge the ceiling: the over-limit step DID happen
      // (the CLI already made the call), so its step and cost are reported
      // with the stop — steps and charges stay consistent.
      state.observe(line)
      if request.max_steps is Some(limit) && state.steps > limit {
        return @shim.Stop
      }
      @shim.Continue
    },
  )
  state.result(exit)
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
  } else {
    args.push("--disallowedTools")
  }
  args.push_iter(mutating.iter())
  args
}

///|
test "argv: read-only by default, writable for worker, extras before the tool list" {
  let request = @shim.Request(
    request_id="r",
    kind="explore",
    input=Json::null(),
    prompt="why?",
  )
  let options = @shim.Options(
    command="claude",
    result_file="/r",
    model="opus",
    extra=["--max-budget-usd", "1"],
  )
  assert_eq(claude_args(request, options, None), [
    "-p", "why?", "--output-format", "stream-json", "--verbose", "--model", "opus",
    "--max-budget-usd", "1", "--disallowedTools", "Edit", "Write", "MultiEdit", "NotebookEdit",
    "Bash",
  ])
  let worker = @shim.Request(
    request_id="r",
    kind="worker",
    input=Json::null(),
    prompt="why?",
  )
  let plain = @shim.Options(command="claude", result_file="/r")
  let writable = @shim.Options(
    command="claude",
    result_file="/r",
    writable=true,
  )
  assert_eq(
    claude_args(request, writable, None),
    claude_args(worker, plain, None),
  )
  assert_eq(claude_args(worker, plain, Some("{}")), [
    "-p", "why?", "--output-format", "stream-json", "--verbose", "--json-schema",
    "{}", "--permission-mode", "acceptEdits", "--allowedTools", "Edit", "Write",
    "MultiEdit", "NotebookEdit", "Bash",
  ])
}

///|
/// The request's schema as the inline JSON text `--json-schema` takes.
fn request_schema(request : @shim.Request) -> String? {
  request.schema.map(schema => schema.stringify())
}

///|
test "the request's schema becomes the inline --json-schema text" {
  let request = @shim.Request(
    request_id="r",
    kind="explore",
    input=Json::null(),
    prompt="why?",
    schema={ "type": "object" },
  )
  assert_eq(request_schema(request), Some("{\"type\":\"object\"}"))
  let unshaped = @shim.Request(
    request_id="r",
    kind="explore",
    input=Json::null(),
    prompt="why?",
  )
  assert_eq(request_schema(unshaped), None)
}
