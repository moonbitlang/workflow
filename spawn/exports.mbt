///|
/// PUBLIC API WITH NO INTERNAL CALLER. `moon ide analyze` reports a `pub`
/// symbol nothing in the workspace uses; the ones here are exported on
/// purpose — a caller outside this repository is the user — so they live
/// in this file to say so, rather than looking like an oversight every
/// time the report is read.

///|
/// Live cost counters, updated AS the child streams. `contract_run` fills
/// them in; nothing in this repository READS them, because the reader is
/// the caller who passed them in.
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
/// this. Nothing in this repository needs that; a live engine does.
pub fn ContractProgress::ContractProgress() -> ContractProgress {
  { steps: 0, prompt_tokens: 0, completion_tokens: 0, cost_usd: None, }
}
