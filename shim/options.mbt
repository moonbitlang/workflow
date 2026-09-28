///|
/// The shim's own argv, shared by both dialects: engine settings that are
/// deployment configuration, never part of the request. Everything after
/// `--` is passed to the CLI verbatim — the escape hatch for a flag the
/// shim does not know yet.
///
///   --result-file <path>  where to write the result (required; the runner
///                     passes its `{result_file}` placeholder here)
///   --command <exe>   the CLI binary (default: the dialect's name on PATH)
///   --model <name>    forwarded as the CLI's model flag
///   --cwd <dir>       the CLI's working directory
///   --writable        write-capable run (default: read-only unless kind = worker)
///   --schema <file>   JSON Schema the final answer must match
///   -- <args...>      passed through to the CLI unchanged
///
/// A dialect READS one; `parse` is how a shim gets it, off argv. A caller
/// fabricating one (a dialect's own tests) goes through `Options(...)`,
/// so a later setting costs no dialect anything.
pub struct Options {
  /// Where the one result file goes (the child contract).
  result_file : String
  command : String
  model : String?
  cwd : String?
  writable : Bool
  schema : String?
  extra : Array[String]
}

///|
/// Options from their parts, for a caller that FABRICATES them instead of
/// parsing argv. Only the binary and the result path are required — every
/// other setting is a flag the operator did not pass, and `writable`
/// defaults to the read-only run that argv defaults to.
pub fn Options::Options(
  command~ : String,
  result_file~ : String,
  model? : String,
  cwd? : String,
  writable? : Bool = false,
  schema? : String,
  extra? : Array[String] = [],
) -> Options {
  { result_file, command, model, cwd, writable, schema, extra, }
}

///|
/// The shim's own flags, as argparse sees them. `--` and everything after
/// it is cut away before parsing, so a passthrough flag can never be read
/// as one of ours (nor ours be swallowed as passthrough).
fn spec(default_command : String) -> @argparse.Command {
  @argparse.Command(
    default_command,
    about=(
      $|Drive the \{default_command} CLI as a workflow child: read one request
      $|line on stdin, write one result file to --result-file. Everything
      $|after `--` reaches the CLI unchanged.
    ),
    options=[
      @argparse.OptionArg(
        "result-file",
        about="where to write the result file",
        required=true,
      ),
      @argparse.OptionArg("command", about="the CLI binary", default_values=[
        default_command,
      ]),
      @argparse.OptionArg("model", about="forwarded as the CLI's model flag"),
      @argparse.OptionArg("cwd", about="the CLI's working directory"),
      @argparse.OptionArg(
        "schema",
        about="file holding the JSON Schema the final answer must match",
      ),
    ],
    flags=[
      @argparse.FlagArg(
        "writable",
        about="write-capable run (default: read-only unless kind = worker)",
      ),
    ],
  )
}

///|
/// Parse the shim's argv (without argv[0]). Unknown options are refused —
/// a typo must not silently become a prompt or a CLI flag.
fn Options::parse(
  args : ArrayView[String],
  default_command~ : String,
) -> Result[Options, String] {
  let cut = args.search("--").unwrap_or(args.length())
  let extra = if cut < args.length() { args[cut + 1:].to_owned() } else { [] }
  let matches = spec(default_command).parse(argv=args[:cut], env=Map([])) catch {
    // Display-ready text: the error and this command's full help.
    error => return Err("\{error}")
  }
  guard first(matches, "result-file") is Some(result_file) &&
    !result_file.is_blank() else {
    return Err("--result-file needs a path")
  }
  Ok({
    result_file,
    command: first(matches, "command").unwrap_or(default_command),
    model: first(matches, "model"),
    cwd: first(matches, "cwd"),
    writable: matches.flags.get("writable").unwrap_or(false),
    schema: first(matches, "schema"),
    extra,
  })
}

///|
/// The first value parsed for an argument, if it was given at all.
fn first(matches : @argparse.Matches, name : String) -> String? {
  match matches.values.get(name) {
    Some([value, ..]) => Some(value)
    _ => None
  }
}
