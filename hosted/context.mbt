// How a workflow that is itself inside a sandbox learns what it may launch.
//
// `contract_runner` answers the outward question: how does a workflow start a
// child process. This package answers the inward one. A script running under a
// sandbox — an agent's scripting tool, a CI step, anything that spawns code it
// did not write — cannot be allowed to CHOOSE the things that make its children
// accounted for: which child ids it may use, where its ledger goes, how many
// children it may start. Those belong to the host that launched it, and the
// host knows them before the script begins.
//
// So the host writes them down and the script reads them here. Nothing is
// discovered: a reader watching the run is told where to look, because the
// host chose the coordinates in advance and can say so.
//
// The library learns no engine's command line. The argv arrives as DATA, with
// two placeholders substituted per call, so `hosted` works for any engine that
// speaks the child contract.

///|
/// The single variable a host writes. One JSON document rather than a family
/// of variables: a handoff is all-or-nothing, and a script that read four of
/// five names would launch children the host never reserved.
const HostVar = "WORKFLOW_HOST"

///|
/// The handoff a host wrote for one run.
///
/// ABSTRACT, like `Runner` and `Journal`: the layout is not the contract. A
/// script passes this value along; every field is a coordinate whose only
/// correct value is the one that arrived, and a script with the standing to
/// rewrite one would have the standing to make its own children unaccountable.
struct Context {
  extensions : Map[String, Json]
  exe : String
  child_args : Array[String]
  child_id : String
  first_child : Int
  child_count : Int
  journal_path : String?
  events_path : String?
  cwd : String?
  deadline_ms : Int?
}

///|
/// A handoff the host DID supply but this release cannot use: not JSON, a
/// handoff version or transport it does not read, or a coordinate missing
/// or malformed. The payload says which.
pub suberror HandoffError {
  HandoffError(String)
}

///|
/// Prints the reason alone, so a script that lets the error escape `main`
/// tells its operator exactly what was wrong with the handoff.
impl Show for HandoffError with fn output(self, logger) {
  let HandoffError(reason) = self
  logger.write_string("unusable WORKFLOW_HOST handoff: \{reason}")
}

///|
/// The handoff, or `None` when this process was not given one.
///
/// `None` — the variable unset, or blank — is an ordinary state, not an
/// error. A script run outside a host (by hand, in a test, by a host with
/// nothing to reserve) simply has no children to delegate to, and may do its
/// own work instead.
///
/// A handoff that WAS supplied but cannot be used raises `HandoffError`. It
/// never reads as `None`: a script that fell back to standalone work on a bad
/// handoff would launch children its host never reserved and cannot see.
pub fn context() -> Context? raise HandoffError {
  guard @env.get_env_var(HostVar) is Some(raw) && !raw.is_blank() else {
    return None
  }
  let json = @json.parse(raw) catch {
    error => raise HandoffError("not JSON: \{error}")
  }
  Some(parse(json))
}

///|
/// The handoff from its JSON form: what `context()` reads, or a
/// `HandoffError` saying why it cannot be used.
///
/// PRIVATE, like the layout it fills. `Context` is abstract so that a script
/// cannot CHOOSE the coordinates that make its children accountable; a public
/// reader taking arbitrary JSON would be a constructor, and hand that standing
/// back through the front door. `context()` is the only way in, and the only
/// coordinates a `Context` can carry are the ones the host wrote down.
///
/// FAIL CLOSED. A document missing any required coordinate, carrying one this
/// package cannot use, or naming a version or transport it does not read is
/// refused whole rather than read as a partial context — a half-read handoff
/// would name child ids the host never reserved, or a ledger path nothing is
/// watching.
///
/// The handoff is version 2 with `"transport": "result_file"`: children
/// write one result file each (the child contract). The discriminator stays
/// on the wire so that this release refuses a handoff meant for any other
/// contract, and an older library refuses this one, rather than either
/// passing arguments it does not understand to a child.
fn parse(json : Json) -> Context raise HandoffError {
  guard json is Object(fields) else { raise HandoffError("not a JSON object") }
  match fields.get("v") {
    Some(Number(2, ..)) => ()
    Some(version) =>
      raise HandoffError(
        "unsupported handoff version \{version.stringify()}; this release reads version 2",
      )
    None => raise HandoffError("no handoff version `v`")
  }
  match fields.get("transport") {
    Some(String("result_file")) => ()
    Some(transport) =>
      raise HandoffError(
        "unsupported transport \{transport.stringify()}; this release reads \"result_file\"",
      )
    None => raise HandoffError("no `transport`")
  }
  // A coordinate that arrived but is unusable is as good as missing: an empty
  // `exe` names no engine, an empty template runs nothing, and a child-id
  // template that consumes no ordinal would name every child alike, so the
  // second to write its transcript would land on the first's.
  guard fields.get("exe") is Some(String(exe)) && !exe.is_empty() else {
    raise HandoffError("`exe` must be a non-empty string")
  }
  guard fields.get("child_args") is Some(Array(items)) &&
    child_argv(items) is Some(child_args) else {
    raise HandoffError("`child_args` must be a non-empty array of strings")
  }
  // A child told nowhere to write its result could never report one.
  guard child_args.any(token => token.contains(@spawn.ResultFilePlaceholder)) else {
    raise HandoffError("`child_args` must name \{@spawn.ResultFilePlaceholder}")
  }
  guard fields.get("child_id") is Some(String(child_id)) &&
    child_id.contains(OrdinalPlaceholder) else {
    raise HandoffError(
      "`child_id` must be a string containing \{OrdinalPlaceholder}",
    )
  }
  // A block of unknown size is not a block: both bounds must be present and
  // positive, and a script that assumed one would be inventing the ceiling it
  // is supposed to be under.
  guard fields.get("ids") is Some(Array([Number(first, ..), Number(count, ..)])) &&
    positive(first) is Some(first_child) &&
    positive(count) is Some(child_count) else {
    raise HandoffError("`ids` must be [first, count], both positive integers")
  }
  let journal_path = optional_string(fields, "journal")
  let events_path = optional_string(fields, "events")
  let cwd = optional_string(fields, "cwd")
  let deadline_ms = match fields.get("deadline_ms") {
    None | Some(Null) => None
    Some(Number(ms, ..)) if positive(ms) is Some(ms) => Some(ms)
    Some(_) => raise HandoffError("`deadline_ms` must be a positive integer")
  }
  let extensions : Map[String, Json] = Map([])
  for key, value in fields {
    match key {
      "v"
      | "transport"
      | "exe"
      | "child_args"
      | "child_id"
      | "ids"
      | "journal"
      | "events"
      | "cwd"
      | "deadline_ms" => ()
      _ => extensions[key] = value
    }
  }
  {
    extensions,
    exe,
    child_args,
    child_id,
    first_child,
    child_count,
    journal_path,
    events_path,
    cwd,
    deadline_ms,
  }
}

///|
/// The child argv template: a non-empty list of strings, or nothing. An empty
/// template names no program to run.
fn child_argv(items : Array[Json]) -> Array[String]? {
  let out : Array[String] = []
  for item in items {
    guard item is String(token) else { return None }
    out.push(token)
  }
  if out.is_empty() {
    None
  } else {
    Some(out)
  }
}

///|
/// A whole, positive JSON number as an `Int`.
fn positive(value : Double) -> Int? {
  let int = value.to_int()
  if int.to_double() == value && int > 0 {
    Some(int)
  } else {
    None
  }
}

///|
/// A path the host may omit. Absent, null, and empty all mean "unset": a host
/// that named no ledger is the same as one that wrote a blank path. Anything
/// else but a string is a malformed handoff.
fn optional_string(
  fields : Map[String, Json],
  name : String,
) -> String? raise HandoffError {
  match fields.get(name) {
    None | Some(Null) | Some(String("")) => None
    Some(String(text)) => Some(text)
    Some(_) => raise HandoffError("`\{name}` must be a string")
  }
}

///|
/// The journal the host told this run to write, when it named one.
pub fn Context::journal_path(self : Context) -> String? {
  self.journal_path
}

///|
/// The sidecar the host told this run to write, when it named one.
pub fn Context::events_path(self : Context) -> String? {
  self.events_path
}

///|
/// How many children this run may start: its reserved block, which is also
/// its ceiling.
pub fn Context::child_capacity(self : Context) -> Int {
  self.child_count
}
