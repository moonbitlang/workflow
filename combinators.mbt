///|
/// Run thunks concurrently and return their results in order, fail-fast:
/// the first thunk that RAISES — a bare `agent` call propagating its
/// `AgentFailed`, an engine bug, cancellation — cancels every sibling still
/// in flight and propagates. The right shape when later work is worthless
/// without ALL of this stage.
///
/// To keep each agent's failure in its own slot instead, use `fan_out`.
pub async fn[T] parallel(thunks : Array[async () -> T]) -> Array[T] {
  @async.all(thunks)
}

///|
/// Fan items out through one async stage and keep each item's outcome as
/// data: `Ok(value)`, or `Err(failure)` when `run` raised a typed
/// `WorkflowError`. One lost agent never cancels its siblings, and tokens
/// already spent on the others stay spent. Pair with `all_ok` /
/// `collect_ok` to choose the policy afterwards.
///
/// `run` is any RAISING step: `agent`, `agent_call` carrying an engine's
/// own input shape, an `agent_as` whose decode may reject, a `retry`
/// around any of them, or a whole multi-stage per-item pipeline.
/// Multi-stage pipelines are function composition inside `run` — stages
/// need no barrier between them, so composing them per-item IS the
/// pipeline, and a raise at any stage lands in that item's slot.
///
/// Only `WorkflowError` is kept. An engine bug or cancellation raised by
/// any item cancels the siblings and propagates: those are never demoted
/// to a slot a policy could quietly discard.
pub async fn[A, B] fan_out(
  items : Array[A],
  run : async (A) -> B,
) -> Array[Result[B, WorkflowError]] {
  parallel(
    items.map(item => {
      () => {
        Ok(run(item)) catch {
          WorkflowError::_ as failure => Err(failure)
          error => raise error
        }
      }
    }),
  )
}

///|
/// Re-run one agent step while it keeps failing retriably: `max_retry`
/// extra attempts at most, spaced by `backoff`, raising the LAST attempt's
/// error when the budget runs out. Wraps a RAISING step (`agent`,
/// `agent_as`, or a whole per-item pipeline). Put it inside `fan_out`'s
/// `run`, not the other way round: an item already settled into a slot
/// raises nothing there is left to retry on.
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
  max_retry~ : Int32 = 1,
  backoff~ : @async.RetryMethod = Immediate,
  retriable~ : (WorkflowError) -> Bool = worth_retrying,
) -> T {
  @async.retry(
    backoff,
    max_retry~,
    // The runtime's own loop already treats cancellation as fatal; this
    // adds the workflow's vocabulary — anything that is not a typed
    // workflow failure is an engine bug and must not be re-run.
    fatal_error=error => {
      match error {
        WorkflowError::_ as failure => !retriable(failure)
        _ => true
      }
    },
    attempt,
  )
}

///|
/// Policy: every slot must have succeeded; re-raise the first failure
/// otherwise. Post-hoc fail-fast — siblings have already run to
/// completion; `parallel` over raising thunks cancels them instead.
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
/// (`QuorumNotReached` otherwise) — the k-of-n gate of a vote panel or an
/// adversarial verification. `min_ok=0` is pure best-effort collection; a
/// negative `min_ok` is treated as 0.
pub fn[T] collect_ok(
  results : Array[Result[T, WorkflowError]],
  min_ok~ : Int32 = 0,
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
