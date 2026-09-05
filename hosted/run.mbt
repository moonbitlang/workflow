// The one entry point a hosted script calls.

///|
/// Run `body` with a workflow wired to the host's handoff.
///
/// Everything a watcher needs is a SIDE EFFECT of running here: children get
/// the ids the host reserved, completions append to the journal, and launches
/// are bracketed in the sidecar. The script's author writes the shape of the
/// work and nothing else — no ids, no paths, no ceiling.
///
/// That is the point. A script that had to pass these itself would put the
/// coordinates that make a run accountable into the same text that decides
/// what the run does, where a plausible-looking wrong value silently produces
/// a run nothing can see.
///
/// `max_concurrent` bounds how many children run at once. The LIFETIME cap is
/// not a parameter: it is the reserved block, which `runner` enforces by
/// refusing calls past its end. A script cannot widen it, because it cannot
/// name a child the host did not reserve.
pub async fn[T] Context::run(
  self : Context,
  body : async (@workflow.Workflow) -> T,
  max_concurrent? : Int = 4,
) -> T {
  let journal = match self.journal_path() {
    Some(path) => @workflow.Journal::load(path)
    // A host that named no journal still gets a working run; only its ledger
    // dies with the process.
    None => @workflow.Journal::in_memory()
  }
  let wf = @workflow.Workflow(runner=self.runner(), max_concurrent~, journal~)
  body(wf)
}
