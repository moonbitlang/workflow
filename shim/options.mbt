///|
/// The shim's own argv, shared by both dialects: engine settings that are
/// deployment configuration, never part of the request. Everything after
/// `--` is passed to the CLI verbatim — the escape hatch for a flag the
/// shim does not know yet.
///
///   --command <exe>   the CLI binary (default: the dialect's name on PATH)
///   --model <name>    forwarded as the CLI's model flag
///   --cwd <dir>       the CLI's working directory
///   --writable        write-capable run (default: read-only unless kind = worker)
///   --schema <file>   JSON Schema the final answer must match
///   -- <args...>      passed through to the CLI unchanged
pub(all) struct Options {
  command : String
  model : String?
  cwd : String?
  writable : Bool
  schema : String?
  extra : Array[String]
}

///|
/// Parse the shim's argv (without argv[0]). Unknown options are refused —
/// a typo must not silently become a prompt or a CLI flag.
pub fn Options::parse(
  args : ArrayView[String],
  default_command~ : String,
) -> Result[Options, String] {
  let mut command = default_command
  let mut model : String? = None
  let mut cwd : String? = None
  let mut writable = false
  let mut schema : String? = None
  let extra : Array[String] = []
  let mut index = 0
  while index < args.length() {
    let arg = args[index]
    fn value(name : String) -> Result[String, String] {
      if index + 1 < args.length() {
        index += 1
        Ok(args[index])
      } else {
        Err("\{name} needs a value")
      }
    }
    match arg {
      "--command" =>
        match value(arg) {
          Ok(v) => command = v
          Err(e) => return Err(e)
        }
      "--model" =>
        match value(arg) {
          Ok(v) => model = Some(v)
          Err(e) => return Err(e)
        }
      "--cwd" =>
        match value(arg) {
          Ok(v) => cwd = Some(v)
          Err(e) => return Err(e)
        }
      "--schema" =>
        match value(arg) {
          Ok(v) => schema = Some(v)
          Err(e) => return Err(e)
        }
      "--writable" => writable = true
      "--" => {
        extra.push_iter(args[index + 1:].iter())
        break
      }
      other => return Err("unknown shim option \{other}")
    }
    index += 1
  }
  Ok({ command, model, cwd, writable, schema, extra, })
}
