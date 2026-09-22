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
/// The handoff from its JSON form: what `context()` reads.
///
/// PRIVATE, like the layout it fills. `Context` is abstract so that a script
/// cannot CHOOSE the coordinates that make its children accountable; a public
/// reader taking arbitrary JSON would be a constructor, and hand that standing
/// back through the front door. `context()` is the only way in, and the only
/// coordinates a `Context` can carry are the ones the host wrote down.
///
/// FAIL CLOSED. A document missing any required coordinate, or carrying a
/// version this package does not know, yields `None` rather than a partial
/// context — a half-read handoff would name child ids the host never reserved,
/// or a ledger path nothing is watching.
fn parse(json : Json) -> Context? {
  guard json
    is {
      "v": 1,
      "exe": String(exe),
      "child_args": Array(child_args),
      "child_id": String(child_id),
      "ids": Array([Number(first, ..), Number(count, ..)]),
      "journal"? : journal,
      "events"? : events,
      "cwd"? : cwd,
      "deadline_ms"? : deadline_ms,
      ..
    } else {
    return None
  }
  // A coordinate that arrived but is unusable is as good as missing: an empty
  // `exe` names no engine, an empty template runs nothing, and a child-id
  // template that consumes no ordinal would name every child alike, so the
  // second to write its transcript would land on the first's.
  guard !exe.is_empty() else { return None }
  guard child_id.contains(OrdinalPlaceholder) else { return None }
  guard child_argv(child_args) is Some(argv) else { return None }
  // A block of unknown size is not a block: both bounds must be present and
  // positive, and a script that assumed one would be inventing the ceiling it
  // is supposed to be under.
  let first_ordinal = first.to_int()
  let ordinal_count = count.to_int()
  guard first_ordinal > 0 && ordinal_count > 0 else { return None }
  let extensions : Map[String, Json] = Map([])
  if json is Object(fields) {
    for key, value in fields {
      match key {
        "v"
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
  }
  Some({
    extensions,
    exe,
    child_args: argv,
    child_id,
    first_child: first_ordinal,
    child_count: ordinal_count,
    journal_path: optional_string(journal),
    events_path: optional_string(events),
    cwd: optional_string(cwd),
    deadline_ms: optional_int(deadline_ms),
  })
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
/// A coordinate the host may omit. Absent, of the wrong type, and empty all
/// mean "unset": a host that named no ledger is the same as one that wrote a
/// blank path.
fn optional_string(value : Json?) -> String? {
  match value {
    Some(String(text)) if !text.is_empty() => Some(text)
    _ => None
  }
}

///|
fn optional_int(value : Json?) -> Int? {
  match value {
    Some(Number(number, ..)) => Some(number.to_int())
    _ => None
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
