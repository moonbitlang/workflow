///|
/// Shared progress API for the hosted runner and external engine adapters,
/// including OpenSeek's parent-side `agent_subrun` runner.

///|
/// Live cost counters, updated AS the child streams. `contract_run` fills
/// them in; the hosted runner reads them during cancellation, and external
/// engines can use the same counters for live progress displays.
pub struct ContractProgress {
  mut steps : Int
  mut prompt_tokens : Int
  mut completion_tokens : Int
  /// Summed `usage.cost_usd`; `None` until a usage line with a valid
  /// price is charged — a present-but-invalid price voids the whole line.
  mut cost_usd : Double?
}

///|
/// Fresh zeroed counters, for a caller that wants to WATCH a run rather
/// than only read its result: `contract_run(progress?)` fills these in as
/// the child streams, so a run torn down by cancellation still leaves its
/// spend behind — the raise unwinds past the return value, but not past
/// this. The hosted runner uses them to close a cancelled launch's sidecar
/// bracket; external engines can report the same observed usage.
pub fn ContractProgress::ContractProgress() -> ContractProgress {
  { steps: 0, prompt_tokens: 0, completion_tokens: 0, cost_usd: None, }
}
