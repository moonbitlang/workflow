// The `Runner` a hosted run spawns through, and the sidecar that makes its
// launches visible while they are still running.

///|
/// The ordinal placeholder in the child-id template.
const OrdinalPlaceholder = "{n}"

///|
/// The call's kind, substituted into the child argv.
const KindPlaceholder = "{kind}"

///|
/// The child's id, substituted into the child argv. The engine is expected to
/// turn it into wherever that child's own record lives; the library only
/// guarantees it is unique and inside the reserved block.
const ChildPlaceholder = "{child}"

///|
/// Default wall deadline for one child, when the host named none.
const DefaultDeadlineMs = 600_000

///|
/// One template token with this call's values filled in.
fn substitute(token : String, kind~ : String, child~ : String) -> String {
  token
  .replace_all(old=KindPlaceholder, new=kind)
  .replace_all(old=ChildPlaceholder, new=child)
}

///|
/// Append one line to the sidecar, best effort.
///
/// A sidecar is a view. A run whose work succeeded must not fail because a
/// progress line could not be written, and the journal — which is the record —
/// has its own durability.
async fn note(path : String?, line : Json) -> Unit {
  guard path is Some(path) else { return }
  @fs.write_file(
    path,
    line.stringify() + "\n",
    append=true,
    create_mode=OpenOrCreate,
  ) catch {
    _ => ()
  }
}

///|
/// A `Runner` that spawns the host's engine, one child per call, into the ids
/// the host reserved.
///
/// Three properties are the reason this is a package rather than an example a
/// caller could paste:
///
/// - Child ids come from the reserved block. The host allocates that block
///   from the same counter it uses for any children of its OWN, so a hosted
///   run's child and a host-launched child cannot collide on one record.
/// - The block is the launch ceiling. A call past its end is refused as
///   `Skipped` rather than launched unnamed: a child with no record is the
///   thing this package exists to prevent, and a script is opaque to its host
///   — one call can loop — so nothing else bounds how many it starts.
/// - Every launch is bracketed in the sidecar. The journal cannot do this: a
///   `JournalEntry` carries an outcome, so it is written when a call RESOLVES,
///   and a reader with only the journal learns of a child no earlier than its
///   completion. The `started` line carries the child id, so a watcher can
///   begin following that child immediately.
///
/// Per-call `max_steps` is not in the argv template. It rides the request
/// (`limits.max_steps`), which is where the contract already carries it — a template with
/// an optional flag in it would need conditional groups to express "omit both
/// tokens when unset".
pub fn Context::runner(self : Context) -> @workflow.Runner {
  self.runner_emitting(note)
}

///|
/// `runner`, with the sidecar writer replaced — the seam a test observes the
/// sidecar through.
fn Context::runner_emitting(
  self : Context,
  emit_line : async (String?, Json) -> Unit,
) -> @workflow.Runner {
  let next = Ref(self.first_child)
  @workflow.Runner(call => {
    guard next.val < self.first_child + self.child_count else {
      return @workflow.DidNotFinish(failure=@workflow.Skipped, attempt=None)
    }
    let ordinal = next.val
    next.val += 1
    let child = self.child_id.replace_all(
      old=OrdinalPlaceholder,
      new="\{ordinal}",
    )
    emit_line(self.events_path, {
      "event": "agent_started",
      "child": child,
      "kind": call.kind,
      "label": call.label,
    })
    // Cancellation unwinds past the result. Close the launch bracket after
    // child teardown without turning the error into an outcome that the
    // workflow could journal. A child reports its spend only in its result,
    // which a launch cut short never reads: the zero counters below are not
    // its account, and the line says so.
    errdefer {
      let (status, unaccounted) = if @async.is_being_cancelled() {
        ("cancelled", "the launch was cancelled before its result was read")
      } else {
        ("failed", "the launch failed before its result was read")
      }
      let finished : Json = {
        "event": "agent_finished",
        "child": child,
        "status": status,
        "steps": 0,
        "tokens": 0,
        "unaccounted": unaccounted,
      }
      @async.protect_from_cancel(() => emit_line(self.events_path, finished))
    }
    // `attempt_id` is the CHILD ID, not an opaque counter: the request id
    // `contract_run` echoes into the attempt. That is what lets a reader join
    // a ledger row to the child's own record — the host knows how it renders
    // a child id, so it can follow the row to whatever that child wrote.
    let outcome = @spawn.contract_run(
        command=self.exe,
        args=self.child_args.map(token => {
          substitute(token, kind=call.kind, child~)
        }),
        input=call.input,
        kind=call.kind,
        id=child,
        max_steps?=call.max_steps,
        schema?=call.schema,
        wall_deadline_ms=self.deadline_ms.unwrap_or(DefaultDeadlineMs),
        cwd?=self.cwd,
      ).outcome
    let finished : Map[String, Json] = {
      "event": "agent_finished",
      "child": child,
      "status": status_of(outcome),
    }
    let attempt = outcome.attempt()
    finished["steps"] = Json(attempt.map(a => a.steps_used).unwrap_or(0))
    finished["tokens"] = Json(
      attempt.map(a => a.prompt_tokens + a.completion_tokens).unwrap_or(0),
    )
    if attempt.bind(a => a.unaccounted) is Some(reason) {
      finished["unaccounted"] = Json::string(reason)
    }
    emit_line(self.events_path, Json::object(finished))
    outcome
  })
}

///|
/// The status word for a finished child, in the contract's own snake_case
/// vocabulary so a reader need not learn a second one.
fn status_of(outcome : @workflow.AgentOutcome) -> String {
  match outcome {
    @workflow.Finished(..) => "captured"
    @workflow.DidNotFinish(failure=@workflow.NoReport, ..) => "no_report"
    @workflow.DidNotFinish(failure=@workflow.MaxSteps, ..) => "max_steps"
    @workflow.DidNotFinish(failure=@workflow.ContextYield, ..) =>
      "context_yield"
    @workflow.DidNotFinish(failure=@workflow.TimedOut, ..) => "timed_out"
    @workflow.DidNotFinish(failure=@workflow.Skipped, ..) => "skipped"
    @workflow.DidNotFinish(failure=@workflow.Failed(_), ..) => "failed"
  }
}
