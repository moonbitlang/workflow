///|
/// PUBLIC API WITH NO INTERNAL CALLER. `moon ide analyze` reports a
/// `pub` symbol nothing in the workspace uses; the ones here are exported
/// on purpose — a caller outside this repository is the user — so they
/// live in this file to say so, rather than looking like an oversight
/// every time the report is read.
///
/// Anything here must earn its place with a reason. A symbol that cannot
/// name its outside caller belongs private, not in this file.

///|
/// Is this failure worth ANOTHER launch? The default `retry` policy, and
/// the vocabulary a caller NARROWS rather than rebuilds
/// (`retriable=e => worth_retrying(e) && …`) — which is why it is public
/// though `retry` is its only caller here:
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
/// Run one call through this runner. A COMPOSING runner — a dispatcher
/// that picks an engine by `kind` and delegates — goes through here, so
/// that composition never reaches for the private field.
pub async fn Runner::invoke(self : Runner, call : AgentCall) -> AgentOutcome {
  (self.run)(call)
}
