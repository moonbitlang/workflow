///|
/// Why a shim ended without a result file. `serve` raises it, and an
/// `async fn main` that lets it escape prints the message on stderr and
/// exits nonzero — the runner then reports that the child left no result.
priv suberror NoResult {
  NoResult(String)
}

///|
impl Show for NoResult with fn output(self, logger) {
  let NoResult(message) = self
  logger.write_string(message)
}

///|
/// A whole shim, as `main`: parse argv into `Options`, read the request
/// line from stdin, hand both to `run`, and write the `ShimResult` it
/// returns to the `--result-file` path (the child contract). stdin stays
/// open afterwards as the parent's cancel channel, which `run_cli` watches.
///
/// Every ending the shim controls writes a result: an error `run` raises is
/// a `failed` result, and so is a malformed request that names its
/// `request_id`. With no result path to write to, no request line, or a
/// malformed request whose id is unknown, `serve` raises instead — let it
/// escape `main`, which prints it and exits nonzero.
pub async fn serve(
  default_command~ : String,
  run~ : async (Options, Request) -> ShimResult,
) -> Unit {
  let options = match Options::parse(@env.args()[1:], default_command~) {
    Ok(options) => options
    Err(problem) => raise NoResult(problem)
  }
  let line = @stdio.stdin.read_until("\n")
  respond(options, line, name="\{default_command} shim", run~)
}

///|
/// `serve` after argv: answer the request `line` (`None` for stdin closed
/// before one arrived) into `options.result_file`. `name` prefixes the
/// diagnostics printed on stderr.
async fn respond(
  options : Options,
  line : String?,
  name~ : String,
  run~ : async (Options, Request) -> ShimResult,
) -> Unit {
  guard line is Some(line) else {
    raise NoResult("\{name}: stdin closed before a request arrived")
  }
  let (request_id, result) = match Request::parse(line) {
    Ok(request) =>
      (
        request.request_id,
        run(options, request) catch {
          error => ShimResult(Failed("\{name} failed: \{error}"))
        },
      )
    Err(problem) =>
      match request_id_of(line) {
        Some(request_id) =>
          (request_id, ShimResult(Failed("malformed request: \{problem}")))
        None => raise NoResult("\{name}: malformed request: \{problem}")
      }
  }
  write_result(options.result_file, request_id, result) catch {
    error =>
      raise NoResult(
        "\{name}: cannot write the result to \{options.result_file}: \{error}",
      )
  }
  // For a human watching stderr; the result file already says it.
  if result.status is Failed(reason) {
    eprintln("\{name}: \{reason}")
  }
}
