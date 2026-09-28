///|
/// The public reader, black box: a script gets a `Context` only from the
/// variable its host wrote, so every path here goes through `WORKFLOW_HOST`.
///
/// A host is emulated by setting that variable, the same way the package
/// README's checked examples do; a script itself never writes it.
async test "the handoff reads from WORKFLOW_HOST, and only from it" {
  // A script run outside a host has nothing to delegate to. That is ordinary,
  // not an error: `context()` returns None, for an unset variable and for a
  // blank one alike.
  @env.unset_env_var("WORKFLOW_HOST")
  guard @hosted.context() is None else { fail("no variable, no context") }
  @env.set_env_var("WORKFLOW_HOST", " ")
  guard @hosted.context() is None else { fail("a blank variable, no context") }
  let document : Json = {
    "v": 2,
    "transport": "result_file",
    "exe": "/opt/engine",
    "child_args": [
      "run", "--input-format", "json", "--cancel-on-stdin-eof", "--kind", "{kind}",
      "--result-file", "{result_file}", "--session", "{child}",
    ],
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
  assert_eq(ctx.extension("transport"), None)
  assert_eq(ctx.child_capacity(), 3)
  assert_eq(ctx.journal_path(), Some("/store/run7.jsonl"))
}

///|
test "a supplied handoff that cannot be used is an error, never no handoff" {
  // Falling back to standalone work on a bad handoff would launch children
  // the host never reserved and cannot see.
  defer @env.unset_env_var("WORKFLOW_HOST")
  for raw in ["not json", "{\"v\":2}", "{\"v\":1,\"exe\":\"/e\"}"] {
    @env.set_env_var("WORKFLOW_HOST", raw)
    let message = try @hosted.context() catch {
      error => {
        // What a script's `main` prints when it lets the error escape.
        let escaped : Error = error
        escaped.to_string()
      }
    } noraise {
      _ => "no error"
    }
    assert_true(message.has_prefix("unusable WORKFLOW_HOST handoff: "))
  }
  @env.set_env_var("WORKFLOW_HOST", "{\"v\":2}")
  let raised = try @hosted.context() catch {
    @hosted.HandoffError(reason) => reason
  } noraise {
    _ => "no error"
  }
  assert_eq(raised, "no `transport`")
}
