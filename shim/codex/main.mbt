///|
/// A PROCESS SHIM: Codex as a workflow engine. Speaks the child contract
/// (`docs/child-contract.md`): one request line on stdin,
/// one result file at `--result-file`. It drives `codex exec --json`
/// underneath and reads that stream for the answer, the usage, and the
/// steps. Point a `LaunchSpec` at the PUBLISHED shim — no build step, no
/// path to hard-code:
///
///   moonx moonbitlang/workflow/shim/codex --result-file {result_file} [--model m] [--cwd d] [--writable] [--schema f] [-- codex args...]
///
/// The runner substitutes a fresh path for `{result_file}`. `moonx` runs the wasm build, which this shim fully
/// supports: it spawns the CLI, keeps the parent's stdin-EOF cancel channel
/// live, and writes the result exactly as the native build does. Building
/// locally (`just shims`) is for developing THIS shim, where the published
/// version is not what you want to run.
///
/// Kind policy: read-only runs (the default) use the `read-only` sandbox;
/// `worker`, or `--writable`, uses `workspace-write`. The request's
/// `limits.max_steps` IS enforced here — each completed non-reasoning item
/// is a step, and the CLI is torn down the moment the ceiling is exceeded —
/// because the CLI has no turn cap of its own. Known limit (verified live
/// on codex-cli 0.151): Codex reports usage only on `turn.completed` and
/// does NOT flush it on SIGINT, so a capped or cancelled run's result
/// carries no usage — the parent records the spend as unaccounted, never
/// as an invented zero.
async fn main {
  @shim.serve(default_command="codex", run~)
}

///|
/// One request, start to finish: the result file's content.
async fn run(
  options : @shim.Options,
  request : @shim.Request,
) -> @shim.ShimResult {
  // Codex takes its schema from a FILE: the call's own schema (request) is
  // written to a scratch directory for the run; `--schema <file>` is the
  // deployment default for scripts that pass none.
  let scratch = match request.schema {
    Some(_) => Some(@fs.tmpdir(prefix="workflow-codex-schema-"))
    None => None
  }
  defer (if scratch is Some(dir) {
    @fs.rmdir(dir, recursive=true) catch {
      _ => ()
    }
  })
  let schema_path = match (request.schema, scratch) {
    (Some(schema), Some(dir)) => {
      let path = "\{dir}/schema.json"
      @fs.write_file(path, schema.stringify())
      Some(path)
    }
    _ => options.schema
  }
  let state = Codex()
  let exit = @shim.run_cli(
    command=options.command,
    args=codex_args(request, options, schema_path),
    cwd?=options.cwd,
    observe=line => {
      // Count first, then judge the ceiling: the over-limit step DID happen
      // (the CLI already made the call), so it is reported with the stop.
      state.observe(line)
      if request.max_steps is Some(limit) && state.steps > limit {
        return @shim.Stop
      }
      @shim.Continue
    },
  )
  state.result(exit, structured=schema_path is Some(_))
}

///|
/// The CLI argv for one request: the prompt is the last positional. Codex
/// reads stdin as ADDITIONAL input even with a prompt on argv ("Reading
/// additional input from stdin…"), so the EOF `run_cli` puts on the CLI's
/// stdin is what keeps it from blocking.
fn codex_args(
  request : @shim.Request,
  options : @shim.Options,
  schema_path : String?,
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
  if schema_path is Some(path) {
    args.push("--output-schema")
    args.push(path)
  }
  args.push_iter(options.extra.iter())
  args.push(request.prompt)
  args
}

///|
test "argv: read-only sandbox by default, workspace-write for worker" {
  let request = @shim.Request(
    request_id="r",
    kind="explore",
    input=Json::null(),
    prompt="why?",
  )
  let options = @shim.Options(
    command="codex",
    result_file="/r",
    model="gpt-5",
    schema="out.json",
    extra=["--ephemeral"],
  )
  assert_eq(codex_args(request, options, options.schema), [
    "exec", "--json", "--skip-git-repo-check", "-s", "read-only", "-m", "gpt-5",
    "--output-schema", "out.json", "--ephemeral", "why?",
  ])
  let worker = @shim.Request(
    request_id="r",
    kind="worker",
    input=Json::null(),
    prompt="why?",
  )
  let plain = @shim.Options(command="codex", result_file="/r")
  assert_eq(codex_args(worker, plain, None), [
    "exec", "--json", "--skip-git-repo-check", "-s", "workspace-write", "why?",
  ])
}
