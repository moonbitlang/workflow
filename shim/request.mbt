///|
/// One request as the runner sent it: the request document
/// (`docs/child-contract.md` §2). `prompt` is derived from `input` the
/// way `Workflow::agent` builds it: a `query` plus optional `hints`.
///
/// A shim READS one; `serve` gets it off the wire. A caller fabricating one
/// (a dialect's own tests) goes through `Request(...)`, so a later request
/// field costs no dialect anything.
pub struct Request {
  /// Echoed in the result, so the runner knows the result answers it.
  request_id : String
  kind : String
  /// `limits.max_steps`: the step ceiling the shim enforces.
  max_steps : Int?
  input : Json
  prompt : String
  /// The JSON Schema the report must satisfy, when the call asked for one;
  /// the shims hand it to the CLI's structured-output flag, and it takes
  /// precedence over a `--schema` file on argv.
  schema : Json?
}

///|
/// A request from its parts, for a caller that FABRICATES one instead of
/// reading it off the wire. The step ceiling and the schema are optional,
/// as on the wire.
pub fn Request::Request(
  request_id~ : String,
  kind~ : String,
  input~ : Json,
  prompt~ : String,
  max_steps? : Int,
  schema? : Json,
) -> Request {
  { request_id, kind, max_steps, input, prompt, schema, }
}

///|
/// Decode the request line: a version 1 request document with a
/// `request_id`, a `kind`, and an `input` that yields a prompt — a `query`
/// string with optional `hints`, a `prompt` string, or a bare string. A
/// present-but-malformed `limits.max_steps` or `schema` is refused, never
/// read as absent: a bad ceiling must not become an unbounded run.
fn Request::parse(line : String) -> Result[Request, String] {
  let trimmed = line.trim(chars="\r\n")
  guard (Some(@json.parse(trimmed.to_owned())) catch { _ => None })
    is Some(json) else {
    return Err("the request is not JSON")
  }
  guard json is Object(fields) else {
    return Err("the request is not a JSON object")
  }
  match fields.get("version") {
    Some(Number(version, ..)) if integral(version) is Some(1) => ()
    Some(Number(version, ..)) =>
      return Err("unsupported request version \{version}")
    _ => return Err("the request has no `version`")
  }
  guard fields.get("request_id") is Some(String(request_id)) else {
    return Err("the request has no `request_id` string")
  }
  guard fields.get("kind") is Some(String(kind)) else {
    return Err("the request has no `kind` string")
  }
  guard fields.get("input") is Some(input) else {
    return Err("the request has no `input`")
  }
  let max_steps = match fields.get("limits") {
    None => None
    Some({ "max_steps": Number(steps, ..), .. }) =>
      match integral(steps) {
        Some(steps) if steps >= 1 => Some(steps)
        _ => return Err("`limits.max_steps` must be an integer of at least 1")
      }
    Some({ "max_steps": _, .. }) =>
      return Err("`limits.max_steps` must be an integer of at least 1")
    Some(Object(_)) => None
    Some(_) => return Err("`limits` must be a JSON object")
  }
  let schema = match fields.get("schema") {
    None | Some(Null) => None
    Some(Object(_) as schema) => Some(schema)
    Some(_) => return Err("`schema` must be a JSON object")
  }
  guard prompt_of(input) is Some(prompt) else {
    return Err("`input` needs a `query` (or `prompt`) string")
  }
  Ok({ request_id, kind, max_steps, input, prompt, schema, })
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
/// The `request_id` of a line `Request::parse` refused, when it names one:
/// the runner accepts a result only for its own request, so a `failed`
/// result can answer a malformed request only if its id is known.
fn request_id_of(line : String) -> String? {
  match
    (Some(@json.parse(line.trim(chars="\r\n").to_owned())) catch { _ => None }) {
    Some({ "request_id": String(request_id), .. }) => Some(request_id)
    _ => None
  }
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
