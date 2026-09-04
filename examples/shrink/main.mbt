///|
/// INTERFACE SHRINKING for any MoonBit module: ask `moon ide analyze` who
/// actually uses each exported item, decide the easy cases WITHOUT
/// spending anything, and put a scout only on the ones that need a
/// judgement — is there a caller outside this repository, or is this
/// surface nobody can reach?
///
///   moon run examples/shrink -- [OPTIONS] [packages...]
///   moon run examples/shrink -- --repo ~/git/openseek --list
///
/// `--list` prints the plan — what was decided mechanically and what is
/// left to judge — and spends NOTHING. That is the whole first half of
/// this workflow, and on most modules it is most of the answer.
///
/// The three mechanical verdicts, in the order they are tried:
///
/// - `explained`: the item lives in an `exports.mbt`, so a previous pass
///   already said why it is public. Never re-litigated.
/// - `unreachable`: its package is an EXECUTABLE. Nothing can import an
///   executable, so every `pub` in one is surface no caller can reach —
///   drop the `pub`, no judgement required.
/// - `narrow`: the tool itself says `(all) or (open) can be removed`.
///   It has already done the reasoning; take the answer.
///
/// What is left is `undecided`: a `pub` with no user in this workspace
/// that might still have one outside it. THAT is what a scout reads the
/// code to settle, one call per package, and the verdict it must return
/// is `drop`, `export`, or `keep` with `file:line` evidence.
///
/// Journal: shrink-api.jsonl (`moon run viz -- shrink-api.jsonl` draws
/// it). The repository path is the replay scope, so one journal can never
/// serve another module's answers. Output: shrink-api.md (`--out`).
async fn main {
  shrink() catch {
    error => println("workflow failed: \{error}")
  }
}

///|
/// One exported item as `moon ide analyze` reports it.
struct Finding {
  pkg : String
  /// The declaration as printed, e.g. `pub fn worth_retrying(...) -> Bool`.
  decl : String
  /// The item sits in an `exports.mbt`: a previous pass explained it.
  explained : Bool
  /// The tool's own `(all) or (open) can be removed`.
  narrowable : Bool
}

///|
/// What this workflow decided about one finding, and who decided.
enum Verdict {
  /// Mechanical, no spend.
  Explained
  Unreachable
  Narrow
  /// Needs a scout: `pub` with no user here, but maybe one elsewhere.
  Undecided
} derive(Eq)

///|
/// A scout's answer for one symbol.
struct Judgement {
  pkg : String
  symbol : String
  verdict : String
  why : String
  evidence : String
}

///|
let judgement_schema : Json = {
  "type": "object",
  "properties": {
    "verdicts": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "symbol": { "type": "string" },
          "verdict": { "type": "string", "enum": ["drop", "export", "keep"] },
          "why": { "type": "string" },
          "evidence": { "type": "string" },
        },
        "required": ["symbol", "verdict", "why", "evidence"],
        "additionalProperties": false,
      },
    },
  },
  "required": ["verdicts"],
  "additionalProperties": false,
}

///|
async fn shrink() -> Unit {
  let spec = @argparse.Command(
    "shrink",
    about="Shrink a MoonBit module's public interface to what its dependents use.",
    options=[
      @argparse.OptionArg(
        "repo",
        short='C',
        long="repo",
        about="the module to shrink",
        default_values=["."],
      ),
      @argparse.OptionArg(
        "engine",
        long="engine",
        about="engine kind: explore, claude, or codex",
        default_values=["explore"],
      ),
      @argparse.OptionArg(
        "journal",
        long="journal",
        about="journal file, for replay and resume",
        default_values=["shrink-api.jsonl"],
      ),
      @argparse.OptionArg(
        "out",
        short='o',
        long="out",
        about="where to write the report",
        default_values=["shrink-api.md"],
      ),
      @argparse.OptionArg(
        "model",
        long="model",
        about="model name for the chosen engine",
      ),
      @argparse.OptionArg(
        "jobs",
        short='j',
        long="jobs",
        about="scouts to run at once",
        default_values=["4"],
      ),
      @argparse.OptionArg(
        "max-calls",
        long="max-calls",
        about="stop launching after this many live calls",
      ),
    ],
    flags=[
      @argparse.FlagArg(
        "list",
        long="list",
        about="print the plan and stop, spending nothing",
      ),
    ],
    positionals=[
      @argparse.PositionArg(
        "packages",
        about="package name suffixes to restrict the sweep to",
        num_args=@argparse.ValueRange(lower=0),
      ),
    ],
  )
  let args = spec.parse() catch {
    error => {
      println("\{error}")
      return
    }
  }
  let repo = @fs.realpath(value(args, "repo", ".")) catch {
    error => {
      println("cannot resolve --repo: \{error}")
      return
    }
  }
  guard module_name(repo) is Some(owner) else {
    println("\{repo} has no moon.mod with a `name` — not a MoonBit module")
    return
  }
  let report = analyze(repo) catch {
    error => {
      println("`moon ide analyze` failed in \{repo}: \{error}")
      return
    }
  }
  let only = args.values.get("packages").unwrap_or([])

  // ---- Scope: the module's OWN packages, never a vendored dependency ----
  // One workspace can hold several modules; a report that mixes them
  // invites a verdict on code this repository does not own.
  let mine : Array[Finding] = []
  let foreign : Array[String] = []
  for finding in parse(report) {
    if owns(owner, finding.pkg) {
      if only.is_empty() || only.iter().any(p => finding.pkg.has_suffix(p)) {
        mine.push(finding)
      }
    } else if !foreign.contains(finding.pkg) {
      foreign.push(finding.pkg)
    }
  }

  // ---- The mechanical half: decide everything that needs no judgement ----
  let executables : Map[String, Bool] = Map([])
  let decided : Array[(Finding, Verdict)] = []
  for finding in mine {
    let executable = match executables.get(finding.pkg) {
      Some(known) => known
      None => {
        let known = is_executable(repo, owner, finding.pkg)
        executables[finding.pkg] = known
        known
      }
    }
    let verdict = if finding.explained {
      Explained
    } else if executable {
      Unreachable
    } else if finding.narrowable {
      Narrow
    } else {
      Undecided
    }
    decided.push((finding, verdict))
  }
  let undecided = decided
    .filter(pair => pair.1 is Undecided)
    .map(pair => pair.0)
  let tally = (verdict : Verdict) => {
    decided.filter(pair => pair.1 == verdict).length()
  }
  println(
    "\{repo} — module \{owner}: \{mine.length()} finding(s) over \{executables.length()} package(s)",
  )
  println(
    "  mechanical: \{tally(Explained)} explained, \{tally(Unreachable)} unreachable, \{tally(Narrow)} narrowable",
  )
  println("  to judge:   \{undecided.length()}")
  if !foreign.is_empty() {
    println(
      "  (skipped \{foreign.length()} package(s) this module does not own)",
    )
  }
  if args.flags.get("list") is Some(true) {
    for pair in decided {
      let (finding, verdict) = pair
      println("  [\{verdict_name(verdict)}] \{finding.pkg}")
      println("      \{finding.decl}")
    }
    return
  }
  guard !undecided.is_empty() else {
    println("nothing left to judge — the mechanical pass settled everything")
    return
  }

  // ---- Routing: the scout reads the module it is judging ----
  let engine = value(args, "engine", "explore")
  let model = match args.values.get("model") {
    Some([value, ..]) => Some(value.trim().to_owned())
    _ => None
  }
  let max_calls = match args.values.get("max-calls") {
    Some([value, ..]) => Some(@string.parse_int(value)) catch { _ => None }
    _ => None
  }
  let shim = "moonbitlang/workflow/shim"
  let wf = @workflow.Workflow(
    runner=@spawn.contract_runner(launch=call => {
      match call.kind {
        "claude" =>
          {
            command: "moonx",
            args: [
              "\{shim}/claude",
              "--model",
              model.unwrap_or("claude-sonnet-5"),
              "--cwd",
              repo,
            ],
            cwd: Some(repo),
            extra_env: None,
            deadline_ms: Some(600_000),
          }
        "codex" =>
          {
            command: "moonx",
            args: [
              "\{shim}/codex",
              "--model",
              model.unwrap_or("gpt-5.3-codex-spark"),
              "--cwd",
              repo,
            ],
            cwd: Some(repo),
            extra_env: None,
            deadline_ms: Some(600_000),
          }
        kind => {
          let argv = ["subrun", kind]
          if call.max_steps is Some(steps) {
            argv.push("--max-steps")
            argv.push("\{steps}")
          }
          {
            command: "openseek",
            args: argv,
            cwd: Some(repo),
            extra_env: None,
            deadline_ms: Some(600_000),
          }
        }
      }
    }),
    journal=@workflow.Journal::load(value(args, "journal", "shrink-api.jsonl")),
    // The repository IS the replay scope: one journal can never serve
    // another module's answers.
    replay_scope=repo,
    max_concurrent=count(args, "jobs", 4),
    max_calls?,
    on_event=event => {
      match event {
        @workflow.PhaseStarted(title) => println("━━ \{title}")
        @workflow.AgentStarted(label~, ..) => println("  ▶ \{label}")
        @workflow.AgentReplayed(label~, ..) =>
          println("  ↺ \{label} (replayed)")
        _ => ()
      }
    },
  )

  // ---- One scout per package: its undecided symbols, and the code ----
  let (judgements, unjudged) = judge(wf, owner, engine, undecided)
  let out = value(args, "out", "shrink-api.md")
  @fs.write_file(
    out,
    render(repo, owner, decided, judgements, unjudged, foreign),
  )
  println(
    "\nwrote \{out}: \{judgements.length()} judgement(s), \{unjudged.length()} package(s) unjudged",
  )
  println(
    "spent \{wf.tokens_spent()} token(s) over \{wf.calls_made()} call(s), \{wf.calls_replayed()} replayed",
  )
}

///|
/// The judging half, over whatever `Workflow` it is handed — which is
/// the seam the tests drive with a fake runner, so the fan-out, the
/// per-package grouping, the answer parsing and the refusal path all run
/// without an engine. One call per package: a scout reads the code once
/// and rules on every undecided symbol in it.
///
/// A package whose scout failed lands in the second array, never in the
/// first: silence about a package is not a clean bill.
async fn judge(
  wf : @workflow.Workflow,
  owner : String,
  engine : String,
  undecided : Array[Finding],
) -> (Array[Judgement], Array[String]) {
  wf.phase("Judge")
  let packages = []
  for finding in undecided {
    if !packages.contains(finding.pkg) {
      packages.push(finding.pkg)
    }
  }
  let judged = @workflow.fan_out(packages, name => {
    let symbols = undecided.filter(f => f.pkg == name).map(f => f.decl)
    @workflow.attempt(() => {
      wf.agent(
        prompt=judge_prompt(owner, name, dir_of(owner, name), symbols),
        kind=engine,
        label="judge:\{name}",
        max_steps=40,
        schema=judgement_schema,
      )
    })
  })
  let judgements : Array[Judgement] = []
  let unjudged : Array[String] = []
  for index, result in judged {
    match result {
      Ok(report) => judgements.append(verdicts_of(packages[index], report))
      Err(error) => unjudged.push("\{packages[index]}: \{error}")
    }
  }
  (judgements, unjudged)
}

///|
/// The one question a scout is asked: for each symbol, is there a caller
/// this workspace cannot see? The answer must cite what it read.
fn judge_prompt(
  owner : String,
  pkg : String,
  dir : String,
  symbols : Array[String],
) -> String {
  let listing = StringBuilder()
  for symbol in symbols {
    listing.write_string("- \{symbol}\n")
  }
  (
    $|`moon ide analyze` says nothing in the `\{owner}` workspace uses these
    $|exported items of package `\{pkg}` (source in `\{dir}/`):
    $|
    $|\{listing}
    $|Read the package and decide each one. Answer with a verdict per symbol:
    $|
    $|- "drop" — no caller outside this module can want it either, so the
    $|  `pub` should go. This is the default: an item is public for a
    $|  reason or it is not public.
    $|- "export" — a caller OUTSIDE this repository is the user, and you
    $|  can say who: a documented extension point, a constructor for a type
    $|  the API hands out, a policy a caller overrides. Name that caller in
    $|  `why`; "someone might" is not naming one.
    $|- "keep" — the tool is wrong and there IS a use in this workspace.
    $|  Cite it.
    $|
    $|`evidence` must be a `file:line` you actually read. A verdict with no
    $|file:line is worthless; say "drop" rather than invent one.
  )
}

///|
/// Run the analyzer in the module being shrunk. `--no-check` is
/// deliberately NOT passed: a report from code that does not compile
/// would be a report about nothing.
async fn analyze(repo : String) -> String {
  let (code, output) = @process.collect_stdout(
    "moon",
    ["ide", "analyze"],
    cwd=repo,
  )
  let text = @utf8.decode_lossy(output.binary())
  guard code == 0 else { fail("exited \{code}\n\{clip(text, 400)}") }
  text
}

///|
/// The analyzer prints a declaration and, in a trailing comment, how many
/// dependents use it. Everything else in the report is structure.
fn parse(report : String) -> Array[Finding] {
  let findings : Array[Finding] = []
  let mut current = ""
  for line in report.split("\n") {
    let text = line.to_owned()
    if text.strip_prefix("package \"") is Some(rest) {
      current = match rest.find("\"") {
        Some(end) => rest.clamped_view(end~).to_owned()
        None => rest.to_owned()
      }
      continue
    }
    guard text.find("// ") is Some(at) else { continue }
    let decl = text.clamped_view(end=at).trim().to_owned()
    let note = text.clamped_view(start=at)
    if decl.is_empty() {
      continue
    }
    if note.has_prefix("// (all) or (open) can be removed") {
      findings.push({ pkg: current, decl, explained: false, narrowable: true, })
      continue
    }
    guard note.strip_prefix("// usage: ") is Some(counts) else { continue }
    let uses = leading_int(counts)
    // Only an item nothing uses is a finding; the rest is just the report
    // telling us the surface is earning its keep.
    if uses == 0 {
      findings.push({
        pkg: current,
        decl,
        explained: note.to_owned().contains("in exports.mbt"),
        narrowable: false,
      })
    }
  }
  findings
}

///|
/// The integer a string starts with, or 0.
fn leading_int(text : StringView) -> Int {
  let digits = StringBuilder()
  for ch in text {
    if ch >= '0' && ch <= '9' {
      digits.write_char(ch)
    } else {
      break
    }
  }
  @string.parse_int(digits.to_string()) catch {
    _ => 0
  }
}

///|
/// The module's own name, from `moon.mod`.
async fn module_name(repo : String) -> String? {
  let text = read_text("\{repo}/moon.mod") catch { _ => return None }
  for line in text.split("\n") {
    let trimmed = line.trim()
    guard trimmed.to_owned().strip_prefix("name") is Some(rest) else {
      continue
    }
    guard rest.trim().to_owned().strip_prefix("=") is Some(value) else {
      continue
    }
    let quoted = value.trim().to_owned()
    guard quoted.strip_prefix("\"") is Some(open) else { continue }
    guard open.find("\"") is Some(end) else { continue }
    return Some(open.clamped_view(end~).to_owned())
  }
  None
}

///|
/// Does this module own that package? A workspace can hold several
/// modules, and a vendored one's surface is not ours to shrink.
fn owns(owner : String, pkg : String) -> Bool {
  pkg == owner || pkg.has_prefix(owner + "/")
}

///|
/// The package's directory, relative to the module root.
fn dir_of(owner : String, pkg : String) -> String {
  if pkg == owner {
    "."
  } else {
    match pkg.strip_prefix(owner + "/") {
      Some(rest) => rest.to_owned()
      None => pkg
    }
  }
}

///|
/// Nothing can import an EXECUTABLE, so every `pub` in one is surface no
/// caller can reach — the cheapest verdict in the sweep, and it needs no
/// model to reach it.
async fn is_executable(repo : String, owner : String, pkg : String) -> Bool {
  let dir = dir_of(owner, pkg)
  let path = if dir == "." {
    "\{repo}/moon.pkg"
  } else {
    "\{repo}/\{dir}/moon.pkg"
  }
  let text = read_text(path) catch { _ => return false }
  text.contains("pkgtype(kind: \"executable\")")
}

///|
async fn read_text(path : String) -> String {
  @utf8.decode_lossy(@fs.read_file(path).binary())
}

///|
/// The verdicts a scout returned, as rows.
fn verdicts_of(pkg : String, report : Json) -> Array[Judgement] {
  let rows : Array[Judgement] = []
  // The report is the CHILD CONTRACT's envelope — `{"answer": …}` — not
  // the answer itself, and an engine that was told a schema may still
  // hand the object back as fenced text. Unwrap before reading.
  guard structured(report) is Some({ "verdicts": Array(items), .. }) else {
    return rows
  }
  for item in items {
    if item
      is {
        "symbol": String(symbol),
        "verdict": String(verdict),
        "why": String(why),
        "evidence": String(evidence),
        ..
      } {
      rows.push({ pkg, symbol, verdict, why, evidence, })
    }
  }
  rows
}

///|
fn render(
  repo : String,
  owner : String,
  decided : Array[(Finding, Verdict)],
  judgements : Array[Judgement],
  unjudged : Array[String],
  foreign : Array[String],
) -> String {
  let out = StringBuilder()
  out.write_string("# Interface shrink — `\{owner}`\n\n")
  out.write_string("`\{repo}`\n\n")
  let mechanical = decided.filter(pair => !(pair.1 is Undecided))
  out.write_string(
    "\{decided.length()} finding(s): \{mechanical.length()} settled mechanically, \{judgements.length()} judged.\n\n",
  )
  for verdict in [Unreachable, Narrow, Explained] {
    let rows = decided.filter(pair => pair.1 == verdict)
    if rows.is_empty() {
      continue
    }
    out.write_string("## \{verdict_name(verdict)}\n\n")
    out.write_string(mechanical_note(verdict) + "\n\n")
    for pair in rows {
      out.write_string("- `\{pair.0.pkg}` — `\{pair.0.decl}`\n")
    }
    out.write_string("\n")
  }
  for name in ["drop", "export", "keep"] {
    let rows = judgements.filter(row => row.verdict == name)
    if rows.is_empty() {
      continue
    }
    out.write_string("## \{name}\n\n")
    for row in rows {
      out.write_string("- `\{row.pkg}` — `\{row.symbol}`\n")
      out.write_string("  - \{row.why}\n")
      out.write_string("  - evidence: `\{row.evidence}`\n")
    }
    out.write_string("\n")
  }
  if !unjudged.is_empty() {
    out.write_string("## Unjudged\n\n")
    out.write_string(
      "Silence about a package is not a clean bill — these were not answered:\n\n",
    )
    for failure in unjudged {
      out.write_string("- \{failure}\n")
    }
    out.write_string("\n")
  }
  if !foreign.is_empty() {
    out.write_string("## Not ours\n\n")
    out.write_string("Packages in the workspace this module does not own:\n\n")
    for name in foreign {
      out.write_string("- `\{name}`\n")
    }
    out.write_string("\n")
  }
  out.to_string()
}

///|
fn verdict_name(verdict : Verdict) -> String {
  match verdict {
    Explained => "explained"
    Unreachable => "unreachable"
    Narrow => "narrowable"
    Undecided => "to judge"
  }
}

///|
fn mechanical_note(verdict : Verdict) -> String {
  match verdict {
    Unreachable =>
      "The package is an executable: nothing can import it, so these `pub`s are surface no caller can reach. Drop the `pub`."
    Narrow =>
      "`moon ide analyze` says `(all) or (open) can be removed` — the wider annotation buys nothing here."
    Explained =>
      "Already in an `exports.mbt`: a previous pass said why these are public. Left alone."
    Undecided => "Needs a judgement."
  }
}

///|
fn value(args : @argparse.Matches, name : String, fallback : String) -> String {
  match args.values.get(name) {
    Some([value, ..]) => value
    _ => fallback
  }
}

///|
/// A positive count from the argv, or the default — a garbage or
/// non-positive value must not silently turn the sweep into nothing.
fn count(args : @argparse.Matches, name : String, fallback : Int) -> Int {
  let parsed = @string.parse_int(value(args, name, "")) catch { _ => 0 }
  if parsed > 0 {
    parsed
  } else {
    fallback
  }
}

///|
/// The ANSWER inside a child-contract report, as an object: the engine
/// was told a schema, but a report still arrives wrapped, and a model
/// told to answer in JSON may still fence it or talk around it.
fn structured(report : Json) -> Json? {
  match report {
    { "answer": String(text), .. } => {
      let body = strip_fences(text)
      match (Some(@json.parse(body)) catch { _ => None }) {
        Some(json) => Some(json)
        None => embedded(body)
      }
    }
    { "answer": value, .. } => Some(value)
    _ => None
  }
}

///|
/// Unwrap a fenced code block: the run of backticks that opened it also
/// closes it, and the closing fence is STRIPPED rather than trimmed, so
/// an answer whose own last character is a backtick keeps it.
fn strip_fences(text : String) -> String {
  let trimmed = text.trim()
  guard trimmed.has_prefix("```") else { return trimmed.to_owned() }
  let opened = trimmed.trim_start(chars="`")
  let fence = trimmed.clamped_view(end=trimmed.length() - opened.length())
  let body = match opened.find("\n") {
    Some(index) => opened.clamped_view(start=index + 1)
    None => opened
  }
  body.strip_suffix(fence).unwrap_or(body).trim().to_owned()
}

///|
/// The FIRST BALANCED `{...}` in a run of prose. An engine that answered
/// and then explained itself still answered, but only a scan to the
/// MATCHING brace finds that answer.
fn embedded(text : String) -> Json? {
  guard text.find("{") is Some(start) else { return None }
  let object = StringBuilder()
  let mut depth = 0
  let mut quoted = false
  let mut escaped = false
  for ch in text.clamped_view(start~) {
    object.write_char(ch)
    if escaped {
      escaped = false
    } else if quoted {
      match ch {
        '\\' => escaped = true
        '"' => quoted = false
        _ => ()
      }
    } else {
      match ch {
        '"' => quoted = true
        '{' => depth += 1
        '}' => {
          depth -= 1
          if depth == 0 {
            return Some(@json.parse(object.to_string())) catch { _ => None }
          }
        }
        _ => ()
      }
    }
  }
  None
}

///|
/// The head of a text, cut where a surrogate pair cannot be split.
fn clip(text : String, limit : Int) -> String {
  text.clamped_view(end=limit).to_owned()
}

///|
/// The parser is the load-bearing half: every verdict downstream is a
/// verdict on what it read out of the report.
test "the report parses into findings, and only unused items are findings" {
  let report =
    #|package "acme/lib"
    #|
    #|pub fn used(String) -> Int    // usage: 6 (2 in test)
    #|
    #|pub fn unused(String) -> Int  // usage: 0 (0 in test)
    #|
    #|pub fn explained() -> Unit    // usage: 0 (0 in test), in exports.mbt
    #|
    #|pub(all) enum Wide {          // (all) or (open) can be removed
    #|  A                           // usage: 3 (0 in test)
    #|}
    #|package "vendor/other"
    #|
    #|pub fn theirs() -> Unit       // usage: 0 (0 in test)
  let findings = parse(report)
  // `used` and `A` never become findings: that surface earns its keep.
  assert_eq(findings.map(f => f.decl), [
    "pub fn unused(String) -> Int", "pub fn explained() -> Unit", "pub(all) enum Wide {",
    "pub fn theirs() -> Unit",
  ])
  assert_eq(findings[0].pkg, "acme/lib")
  assert_false(findings[0].explained)
  assert_true(findings[1].explained)
  assert_true(findings[2].narrowable)
  assert_eq(findings[3].pkg, "vendor/other")
}

///|
/// A scout that answers from the CHILD CONTRACT's envelope, the way a
/// real one does: the verdicts ride `answer`, not the report root. One
/// package answers in fenced prose, because engines do that; one refuses.
async fn scripted(call : @workflow.AgentCall) -> @workflow.AgentOutcome {
  @async.pause()
  let attempt : @workflow.AgentAttempt = {
    attempt_id: "sr-\{call.label}",
    steps_used: 1,
    prompt_tokens: 20,
    completion_tokens: 10,
    cost_usd: None,
  }
  if call.label == "judge:acme/lib/broken" {
    return DidNotFinish(failure=TimedOut, attempt=Some(attempt))
  }
  let answer = if call.label == "judge:acme/lib/fenced" {
    (
      $|Here is my ruling:
      $|```json
      $|{"verdicts": [{"symbol": "pub fn stray() -> Unit", "verdict": "drop",
      $|"why": "no caller anywhere", "evidence": "lib/stray.mbt:4"}]}
      $|```
    )
  } else {
    (
      $|{"verdicts": [
      $|{"symbol": "pub fn keep_me() -> Unit", "verdict": "export",
      $| "why": "the documented extension point", "evidence": "lib/api.mbt:12"},
      $|{"symbol": "malformed"}]}
    )
  }
  Finished(value={ "answer": answer, "engine": "fake" }, attempt~)
}

///|
async test "judging fans out per package, unwraps the envelope, keeps refusals visible" {
  let wf = @workflow.Workflow(runner=@workflow.Runner(scripted))
  let undecided : Array[Finding] = [
    {
      pkg: "acme/lib/api",
      decl: "pub fn keep_me() -> Unit",
      explained: false,
      narrowable: false,
    },
    {
      pkg: "acme/lib/api",
      decl: "pub fn other() -> Unit",
      explained: false,
      narrowable: false,
    },
    {
      pkg: "acme/lib/fenced",
      decl: "pub fn stray() -> Unit",
      explained: false,
      narrowable: false,
    },
    {
      pkg: "acme/lib/broken",
      decl: "pub fn lost() -> Unit",
      explained: false,
      narrowable: false,
    },
  ]
  let (judgements, unjudged) = judge(wf, "acme/lib", "explore", undecided)
  // One call per PACKAGE, not per symbol: `api` has two undecided symbols
  // and is asked once.
  assert_eq(wf.calls_made(), 3)
  assert_eq(judgements.map(row => (row.pkg, row.symbol, row.verdict)), [
    ("acme/lib/api", "pub fn keep_me() -> Unit", "export"),
    ("acme/lib/fenced", "pub fn stray() -> Unit", "drop"),
  ])
  assert_eq(judgements[0].evidence, "lib/api.mbt:12")
  // The malformed row is dropped rather than becoming a half-verdict, and
  // the package whose scout failed is named instead of passing silently.
  assert_eq(unjudged.length(), 1)
  assert_true(unjudged[0].has_prefix("acme/lib/broken: "))
}

///|
test "a report is read through the envelope, however the engine wrapped it" {
  let rows = verdicts_of("p", {
    "answer": "{\"verdicts\": [{\"symbol\": \"s\", \"verdict\": \"drop\", \"why\": \"w\", \"evidence\": \"f:1\"}]}",
    "engine": "fake",
  })
  assert_eq(rows.map(r => r.symbol), ["s"])
  // A structured answer, not a string, is read the same way.
  assert_eq(verdicts_of("p", { "answer": { "verdicts": [] } }).length(), 0)
  // A report that is not the envelope at all yields nothing, never a
  // half-parse.
  assert_eq(verdicts_of("p", { "verdicts": [] }).length(), 0)
}

///|
test "the report separates what was decided for free from what was judged" {
  let finding : Finding = {
    pkg: "acme/lib/cli",
    decl: "pub fn helper() -> Unit",
    explained: false,
    narrowable: false,
  }
  let page = render(
    "/tmp/acme",
    "acme/lib",
    [(finding, Unreachable), ({ ..finding, pkg: "acme/lib/api", }, Undecided)],
    [
      {
        pkg: "acme/lib/api",
        symbol: "pub fn helper() -> Unit",
        verdict: "drop",
        why: "nothing outside wants it",
        evidence: "api/helper.mbt:9",
      },
    ],
    ["acme/lib/late: timed out"],
    ["vendor/other"],
  )
  assert_true(page.contains("# Interface shrink — `acme/lib`"))
  assert_true(page.contains("## unreachable"))
  assert_true(page.contains("## drop"))
  assert_true(page.contains("`api/helper.mbt:9`"))
  // A package that was never answered is named, not quietly omitted.
  assert_true(page.contains("## Unjudged"))
  assert_true(page.contains("acme/lib/late: timed out"))
  // And code this module does not own is kept separate from its own.
  assert_true(page.contains("## Not ours"))
  assert_true(page.contains("`vendor/other`"))
}

///|
test "ownership is by package path, never by a lookalike prefix" {
  assert_true(owns("acme/lib", "acme/lib"))
  assert_true(owns("acme/lib", "acme/lib/deep/pkg"))
  assert_false(owns("acme/lib", "vendor/other"))
  // The trap: `acme/library` starts with `acme/lib` but is another module.
  assert_false(owns("acme/lib", "acme/library"))
  assert_eq(dir_of("acme/lib", "acme/lib"), ".")
  assert_eq(dir_of("acme/lib", "acme/lib/deep/pkg"), "deep/pkg")
}
