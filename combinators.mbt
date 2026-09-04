///|
/// Run thunks concurrently, each already carrying its failure policy in
/// its type: a thunk resolves to `Result[T, WorkflowError]` (build them
/// from `try_agent`), so one agent's failure lands in its own slot without
/// disturbing siblings — tokens already spent on the others stay spent.
/// Anything a thunk RAISES is deliberately not caught: engine bugs and
/// cancellation fail the task group and cancel every peer, never demoted
/// to a slot a policy could quietly discard. Pair with `all_ok` /
/// `collect_ok` / `quorum` to choose the policy in one identifier.
pub async fn[T] parallel(
  thunks : Array[async () -> Result[T, WorkflowError]],
) -> Array[Result[T, WorkflowError]] {
  @async.all(thunks)
}

///|
/// Fail-fast fan-out: the first thunk to RAISE (an `agent` call
/// propagating its `AgentFailed`, an engine bug, cancellation) cancels
/// every sibling still in flight and propagates. The right shape when
/// later work is worthless without ALL of this stage — otherwise prefer
/// `parallel`, which keeps what succeeded.
pub async fn[T] parallel_all(thunks : Array[async () -> T]) -> Array[T] {
  @async.all(thunks)
}

///|
/// Fan items out through one async stage, one `Result` slot per item.
/// Multi-stage pipelines are function composition inside `run` — stages
/// need no barrier between them, so composing them per-item IS the
/// pipeline.
pub async fn[A, B] fan_out(
  items : Array[A],
  run : async (A) -> Result[B, WorkflowError],
) -> Array[Result[B, WorkflowError]] {
  parallel(items.map(item => () => run(item)))
}

///|
/// Fold the typed error channel into the return value: a workflow-level
/// failure lands in `Err`, while cancellation and engine bugs still
/// propagate — the distinction the whole failure model rests on.
///
/// `try_agent` is this move over `agent`, and `attempt` is the same move
/// over ANY raising step: `agent_call` carrying an engine's own input
/// shape, an `agent_as` whose decode may reject, a `retry` around either,
/// or a whole multi-stage per-item pipeline. It exists so the shape a
/// caller wants never has to be a method — one free function covers every
/// entry point instead of a `try_` twin for each.
///
/// The right shape at fan-out call sites, where one lost agent must not
/// poison its siblings.
pub async fn[T] attempt(step : async () -> T) -> Result[T, WorkflowError] {
  Ok(step()) catch {
    AgentFailed(..) as failure => Err(failure)
    CallBudgetExhausted(..) as failure => Err(failure)
    QuorumNotReached(..) as failure => Err(failure)
    error => raise error
  }
}

///|
/// Is this failure worth ANOTHER launch? The default `retry` policy, and
/// the vocabulary a caller narrows rather than rebuilds:
///
/// - an agent that produced no usable report is retriable — a model that
///   timed out, blew its step ceiling, or answered off-schema may well
///   answer on the next attempt;
/// - `Skipped` is NOT: a human declined this call, and retrying overrides
///   that decision exactly as replaying it would (the journal keeps a
///   recorded skip standing for the same reason);
/// - `CallBudgetExhausted` and `QuorumNotReached` are not: the allowance
///   is already gone, and a quorum is the caller's verdict over a whole
///   fan-out, not one call's misfortune.
pub fn worth_retrying(error : WorkflowError) -> Bool {
  match error {
    AgentFailed(failure=Skipped, ..) => false
    AgentFailed(..) => true
    CallBudgetExhausted(..) | QuorumNotReached(..) => false
  }
}

///|
/// Re-run one agent step while it keeps failing retriably: `max_retry`
/// extra attempts at most, spaced by `backoff`, raising the LAST attempt's
/// error when the budget runs out. Wraps a RAISING step (`agent`,
/// `agent_as`, or a whole per-item pipeline) — `try_agent` has already
/// folded its failure into a value there is nothing left to retry on.
///
/// What counts as retriable is `worth_retrying` unless `retriable` says
/// otherwise; cancellation and engine bugs are never retried, they
/// propagate on the first raise.
///
/// `backoff` is the async runtime's own `RetryMethod`, and NAMING one
/// (`FixedDelay(500)`) needs `moonbitlang/async` in the caller's
/// `moon.pkg` — a re-export cannot lend it, since an aliased type still
/// resolves through the package that owns it. The default needs nothing.
///
/// Every attempt is a full LAUNCH: it queues for a slot, debits the launch
/// allowance, and charges its tokens — so `max_calls` must be sized with
/// re-attempts in mind, exactly as it must for resume. Journal replay is
/// unaffected: a failed attempt is recorded and never replayed, so a
/// resumed run replays the attempt that finally succeeded.
pub async fn[T] retry(
  attempt : async () -> T,
  max_retry? : Int = 1,
  backoff? : @async.RetryMethod = Immediate,
  retriable? : (WorkflowError) -> Bool = worth_retrying,
) -> T {
  @async.retry(
    backoff,
    max_retry~,
    // The runtime's own loop already treats cancellation as fatal; this
    // adds the workflow's vocabulary — anything that is not a typed
    // workflow failure is an engine bug and must not be re-run.
    fatal_error=error => {
      match error {
        AgentFailed(..) as failure => !retriable(failure)
        CallBudgetExhausted(..) as failure => !retriable(failure)
        QuorumNotReached(..) as failure => !retriable(failure)
        _ => true
      }
    },
    attempt,
  )
}

///|
/// Policy: every slot must have succeeded; re-raise the first failure
/// otherwise. Post-hoc fail-fast — siblings have already run to
/// completion; use `parallel_all` when failure should cancel them instead.
pub fn[T] all_ok(
  results : Array[Result[T, WorkflowError]],
) -> Array[T] raise WorkflowError {
  let ok = []
  for result in results {
    match result {
      Ok(value) => ok.push(value)
      Err(error) => raise error
    }
  }
  ok
}

///|
/// Policy: keep the successes, requiring at least `min_ok` of them
/// (`QuorumNotReached` otherwise). `min_ok=0` is pure best-effort
/// collection; a negative `min_ok` is treated as 0.
pub fn[T] collect_ok(
  results : Array[Result[T, WorkflowError]],
  min_ok? : Int = 0,
) -> Array[T] raise WorkflowError {
  let ok = []
  for result in results {
    if result is Ok(value) {
      ok.push(value)
    }
  }
  if ok.length() < min_ok {
    raise QuorumNotReached(need=min_ok, ok=ok.length(), of=results.length())
  }
  ok
}

///|
/// Policy: k-of-n agreement gates (adversarial verification, vote panels):
/// at least `need` slots must have succeeded.
pub fn[T] quorum(
  results : Array[Result[T, WorkflowError]],
  need~ : Int,
) -> Array[T] raise WorkflowError {
  collect_ok(results, min_ok=need)
}
