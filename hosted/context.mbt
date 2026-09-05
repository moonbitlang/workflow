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
/// Opaque on purpose. A script passes this value along; every field is a
/// coordinate whose only correct value is the one that arrived, and a script
/// with the standing to rewrite one would have the standing to make its own
/// children unaccountable.
pub struct Context {
  priv exe : String
  priv child_args : Array[String]
  priv child_id : String
  priv first_child : Int
  priv child_count : Int
  priv journal_path : String?
  priv events_path : String?
  priv cwd : String?
  priv deadline_ms : Int?
}

///|
/// The handoff, or `None` when this process was not given one.
///
/// `None` is an ordinary state, not an error. A script run outside a host — by
/// hand, in a test, by a host with nothing to reserve — simply has no children
/// to delegate to, and should do its own work rather than fail.
pub fn context() -> Context? {
  guard @env.get_env_var(HostVar) is Some(raw) else { return None }
  parse(@json.parse(raw) catch { _ => return None })
}

///|
/// The handoff from its JSON form: what `context()` reads, exposed so a host
/// can build the document it is about to write and check it round-trips, and
/// so tests need no environment.
///
/// FAIL CLOSED. A document missing any required coordinate, or carrying a
/// version this package does not know, yields `None` rather than a partial
/// context — a half-read handoff would name child ids the host never reserved,
/// or a ledger path nothing is watching.
pub fn parse(json : Json) -> Context? {
  guard json is Object(fields) else { return None }
  guard fields.get("v") is Some(Number(1, ..)) else { return None }
  guard string_at(fields, "exe") is Some(exe) &&
    string_at(fields, "child_id") is Some(child_id) &&
    strings_at(fields, "child_args") is Some(child_args) &&
    ids_at(fields) is Some((first_child, child_count)) else {
    return None
  }
  // A child id template that consumes no ordinal would name every child alike,
  // and the second to write its transcript would land on the first's.
  guard child_id.contains(OrdinalPlaceholder) else { return None }
  Some({
    exe,
    child_args,
    child_id,
    first_child,
    child_count,
    journal_path: string_at(fields, "journal"),
    events_path: string_at(fields, "events"),
    cwd: string_at(fields, "cwd"),
    deadline_ms: int_at(fields, "deadline_ms"),
  })
}

///|
/// The reserved ordinals, as `[first, count]`. Both must be present together
/// and positive: a block of unknown size is not a block, and a script that
/// assumed one would be inventing the ceiling it is supposed to be under.
fn ids_at(fields : Map[String, Json]) -> (Int, Int)? {
  guard fields.get("ids") is Some(Array([first, count])) else { return None }
  guard first is Number(first, ..) && count is Number(count, ..) else {
    return None
  }
  let first = first.to_int()
  let count = count.to_int()
  if first > 0 && count > 0 {
    Some((first, count))
  } else {
    None
  }
}

///|
fn string_at(fields : Map[String, Json], name : String) -> String? {
  match fields.get(name) {
    Some(String(value)) if !value.is_empty() => Some(value)
    _ => None
  }
}

///|
fn int_at(fields : Map[String, Json], name : String) -> Int? {
  match fields.get(name) {
    Some(Number(value, ..)) => Some(value.to_int())
    _ => None
  }
}

///|
fn strings_at(fields : Map[String, Json], name : String) -> Array[String]? {
  guard fields.get(name) is Some(Array(items)) else { return None }
  let out : Array[String] = []
  for item in items {
    guard item is String(value) else { return None }
    out.push(value)
  }
  if out.is_empty() {
    None
  } else {
    Some(out)
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

///|
test "a complete handoff reads, and a partial one does not" {
  let document : Json = {
    "v": 1,
    "exe": "/opt/engine",
    "child_args": ["subrun", "{kind}", "--session", "{child}"],
    "child_id": "run7-sr-{n}",
    "ids": [5, 32],
    "journal": "/store/run7-wf-5.jsonl",
  }
  guard parse(document) is Some(ctx) else { fail("a full document must read") }
  assert_eq(ctx.child_capacity(), 32)
  assert_eq(ctx.journal_path(), Some("/store/run7-wf-5.jsonl"))
  // The sidecar is optional: a host that wants only a ledger names no events
  // file, and the run still accounts for itself.
  assert_eq(ctx.events_path(), None)
}

///|
test "an incomplete or unknown handoff is refused outright" {
  // Fail closed on every missing coordinate. Each of these would otherwise
  // produce children the host never reserved, or a ledger nothing watches.
  assert_true(
    parse({ "v": 1, "child_args": ["run"], "child_id": "c-{n}", "ids": [1, 4] })
    is None,
  )
  assert_true(
    parse({ "v": 1, "exe": "/e", "child_id": "c-{n}", "ids": [1, 4] }) is None,
  )
  assert_true(
    parse({ "v": 1, "exe": "/e", "child_args": ["run"], "ids": [1, 4] }) is None,
  )
  assert_true(
    parse({ "v": 1, "exe": "/e", "child_args": ["run"], "child_id": "c-{n}" })
    is None,
  )
  // An unknown contract version is refused rather than read optimistically.
  assert_true(
    parse({
      "v": 2,
      "exe": "/e",
      "child_args": ["run"],
      "child_id": "c-{n}",
      "ids": [1, 4],
    })
    is None,
  )
  // A child id template that consumes no ordinal names every child alike, and
  // the second child to write its record would land on the first's.
  assert_true(
    parse({
      "v": 1,
      "exe": "/e",
      "child_args": ["run"],
      "child_id": "fixed",
      "ids": [1, 4],
    })
    is None,
  )
  // A zero-sized block is not a block.
  assert_true(
    parse({
      "v": 1,
      "exe": "/e",
      "child_args": ["run"],
      "child_id": "c-{n}",
      "ids": [1, 0],
    })
    is None,
  )
  // Not JSON, or not an object at all.
  assert_true(parse(Json::string("nope")) is None)
}
