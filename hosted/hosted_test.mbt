///|
/// The public reader, black box: a script gets a `Context` only from the
/// variable its host wrote, so every path here goes through `WORKFLOW_HOST`.
///
/// A host is emulated by setting that variable, the same way the package
/// README's checked examples do; a script itself never writes it.
async test "the handoff reads from WORKFLOW_HOST, and only from it" {
  // A script run outside a host has nothing to delegate to. That is ordinary,
  // not an error: `context()` returns None and the script does its own work.
  @env.unset_env_var("WORKFLOW_HOST")
  guard @hosted.context() is None else { fail("no variable, no context") }
  let document : Json = {
    "v": 1,
    "exe": "/opt/engine",
    "child_args": ["subrun", "{kind}", "--session", "{child}"],
    "child_id": "run7-sr-{n}",
    "ids": [5, 3],
    "journal": "/store/run7.jsonl",
    "openseek": { "audit": { "goal": "ship", "dirty": false } },
    "empty": null,
    "custom": [1, "two"],
  }
  @env.set_env_var("WORKFLOW_HOST", document.stringify())
  defer @env.unset_env_var("WORKFLOW_HOST")
  guard @hosted.context() is Some(ctx) else {
    fail("a complete document must read")
  }
  assert_eq(
    ctx.extension("openseek"),
    Some({ "audit": { "goal": "ship", "dirty": false } }),
  )
  assert_true(ctx.extension("empty") is Some(Null))
  assert_eq(ctx.extension("custom"), Some([1, "two"]))
  assert_eq(ctx.extension("missing"), None)
  assert_eq(ctx.extension("exe"), None)
  assert_eq(ctx.child_capacity(), 3)
  assert_eq(ctx.journal_path(), Some("/store/run7.jsonl"))
  // The sidecar is optional: a host that named no events file gets none.
  assert_eq(ctx.events_path(), None)
  // Fail closed on a version this release does not know, and on input that is
  // not a document at all.
  @env.set_env_var("WORKFLOW_HOST", "{\"v\":2}")
  assert_true(@hosted.context() is None)
  @env.set_env_var("WORKFLOW_HOST", "not json")
  assert_true(@hosted.context() is None)
}
