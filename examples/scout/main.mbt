///|
/// A WORKFLOW SCRIPT: the shape a generated or hand-written orchestration
/// takes. Its whole dependency closure is `moonbitlang/workflow` (plus its
/// `spawn` sub-package) — the engine is just a binary path in argv[1]
/// that speaks the child contract.
///
///   moon run workflow/examples/scout -- <engine> [--journal j.jsonl] [--kind k] [--model m]
///
/// With no kind, three `subrun echo` probes run keylessly. With
/// `--kind explore` (and optionally a model name), one real read-only
/// scout answers a question about the repository — the provider key rides
/// the inherited environment, exactly as the contract prescribes. Run
/// twice with a journal path to watch the second generation replay from
/// the journal instead of spawning any children.
async fn main {
  let spec = @argparse.Command(
    "scout",
    about="Run a few probes through an engine that speaks the child contract.",
    arg_required_else_help=true,
    options=[
      @argparse.OptionArg(
        "journal",
        about="journal to record into and replay from (default: in memory)",
      ),
      @argparse.OptionArg("kind", about="the call kind the engine dispatches", default_values=[
        "echo",
      ]),
      @argparse.OptionArg("model", about="engine setting, forwarded in argv"),
    ],
    positionals=[
      @argparse.PositionArg(
        "engine",
        about="the engine binary to spawn",
        num_args=@argparse.ValueRange(lower=1, upper=1),
      ),
    ],
  )
  // Parse failures and `--help` carry their own contextual help text.
  let args = spec.parse() catch {
    error => {
      println("\{error}")
      return
    }
  }
  guard first(args, "engine") is Some(exe) else { return }
  let journal = match first(args, "journal") {
    Some(path) => @workflow.Journal::load(path)
    None => @workflow.Journal::in_memory()
  }
  let kind = first(args, "kind").unwrap_or("echo")
  let model = first(args, "model")
  let wf = @workflow.Workflow(
    runner=@spawn.contract_runner(launch=call => {
      // The script owns its launch: the request ENVELOPE already carries
      // kind and the step ceiling, so argv holds only engine settings.
      // The API key is NEVER here — it rides the inherited environment.
      let argv = ["subrun", call.kind]
      if call.max_steps is Some(steps) {
        argv.push("--max-steps")
        argv.push("\{steps}")
      }
      if model is Some(model) {
        argv.push("--model")
        argv.push(model)
      }
      {
        command: exe,
        args: argv,
        cwd: None,
        extra_env: None,
        deadline_ms: None,
      }
    }),
    max_concurrent=4,
    max_calls=16,
    journal~,
    on_event=event => {
      match event {
        @workflow.AgentStarted(label~, ..) => println("  ▶ \{label}")
        @workflow.AgentReplayed(label~, ..) =>
          println("  ↺ \{label} (replayed)")
        _ => ()
      }
    },
  )
  wf.phase("Scout")
  let results = if kind == "echo" {
    // Three keyless probes; each is one child process of the engine.
    @workflow.fan_out(["alpha", "beta", "gamma"], probe => {
      wf.try_agent(prompt="probe \{probe}", kind="echo", label="scout:\{probe}")
    })
  } else {
    // One REAL scout: a model-driven read-only agent over this
    // repository, bounded by a small step ceiling.
    [
      wf.try_agent(
        prompt="What kinds does `openseek subrun` dispatch, and where is the dispatch? Answer in one sentence.",
        kind~,
        hints="cmd/openseek/subrun.mbt",
        label="scout:subrun-kinds",
        max_steps=24,
      ),
    ]
  }
  // Report per slot: a failed agent is a printed line, not a crash —
  // the typed error channel makes the choice explicit.
  for result in results {
    match result {
      Ok(answer) => println("  report: \{answer.stringify()}")
      Err(error) => println("  FAILED: \{error}")
    }
  }
  println(
    "launched \{wf.calls_made()} children, replayed \{wf.calls_replayed()}, spent \{wf.tokens_spent()} tokens",
  )
}

///|
/// The first value parsed for an argument, if it was given at all.
fn first(args : @argparse.Matches, name : String) -> String? {
  match args.values.get(name) {
    Some([value, ..]) => Some(value)
    _ => None
  }
}
