///|
/// One journal record: an agent call's work identity, what it resolved
/// to, and the attribution a reader wants — the phase the call was issued
/// under and the wall-clock window it ran in. The journal is the
/// workflow's durability seam: everything a resumed run needs to skip
/// re-paying for work already done rides these entries, so the entry must
/// lose nothing the live run knew (hence `AgentOutcome`, the lossless
/// envelope, and not just the value). Attribution is metadata: replay
/// matches on the call's work identity alone, never on phase or time.
pub struct JournalEntry {
  call : AgentCall
  outcome : AgentOutcome
  /// The workflow phase the call was ISSUED under (`Workflow::phase`), when
  /// there was one. Absent from the line when `None`.
  phase : String?
  /// Milliseconds since the Unix epoch when the runner was invoked, and
  /// when its outcome resolved. Absent when the entry was built without
  /// them (an older journal, a hand-seeded entry). A replayed call writes
  /// no entry, so no entry ever describes a replay.
  started_at : Int64?
  finished_at : Int64?
} derive(Eq)

///|
/// The dot-callable form of the derived equality methods is a migration
/// convenience, not API: compare with `==` / `!=` (through the `Eq`
/// trait) instead.
#deprecated("Use == / != (the Eq trait) instead of the attached equal/not_equal method")
#doc(hidden)
pub extend JournalEntry with Eq::{equal, not_equal}

///|
/// The dot-callable form of the entry's storage codec is a migration
/// convenience, not API: serialize with `Json(value)` or
/// `ToJson::to_json(value)` instead.
#deprecated("Use Json(value) or ToJson::to_json(value) instead of the attached to_json method")
#doc(hidden)
pub extend JournalEntry with ToJson::{to_json}

///|
/// The dot-callable form of the entry's storage codec is a migration
/// convenience, not API: decode through the `@json.FromJson` trait
/// (`@json.from_json`) instead.
#deprecated("Use @json.from_json or FromJson::from_json(json, path) instead of the attached from_json method")
#doc(hidden)
pub extend JournalEntry with FromJson::{from_json}

///|
/// An entry from its parts. Attribution is optional, so a caller seeding a
/// journal by hand (tests, migrations) names only what it knows.
pub fn JournalEntry::JournalEntry(
  call~ : AgentCall,
  outcome~ : AgentOutcome,
  phase? : String,
  started_at? : Int64,
  finished_at? : Int64,
) -> JournalEntry {
  { call, outcome, phase, started_at, finished_at, }
}

///|
/// The entry's storage shape: `call` and `outcome` as their own codecs
/// render them, attribution fields present only when known, and
/// timestamps as plain JSON numbers of milliseconds — the shape every
/// JSON reader expects, rather than the string the default `Int64` codec
/// writes.
pub impl ToJson for JournalEntry with fn to_json(self) {
  let json : Json = { "call": self.call, "outcome": self.outcome }
  guard json is Object(fields) else { return json }
  if self.phase is Some(phase) {
    fields["phase"] = phase.to_json()
  }
  if self.started_at is Some(at) {
    fields["started_at"] = Json::number(at.to_double())
  }
  if self.finished_at is Some(at) {
    fields["finished_at"] = Json::number(at.to_double())
  }
  json
}

///|
/// Decodes the shape `to_json` writes and the pre-attribution shape
/// (`call` and `outcome` alone) that earlier journals hold. A present
/// attribution field of the wrong type is a malformed entry, never a
/// missing one; `null` reads as absent.
pub impl @json.FromJson for JournalEntry with fn from_json(json, path) {
  guard json is { "call": call, "outcome": outcome, .. } else {
    raise JsonDecodeError(
      (path, "JournalEntry: expected an object with `call` and `outcome`"),
    )
  }
  let call = @json.FromJson::from_json(call, path.add_key("call"))
  let outcome = @json.FromJson::from_json(outcome, path.add_key("outcome"))
  let phase = match json {
    { "phase": String(phase), .. } => Some(phase)
    { "phase": Null, .. } => None
    { "phase": _, .. } =>
      raise JsonDecodeError(
        (path.add_key("phase"), "JournalEntry: phase must be a string"),
      )
    _ => None
  }
  {
    call,
    outcome,
    phase,
    started_at: millis(json, "started_at", path),
    finished_at: millis(json, "finished_at", path),
  }
}

///|
/// An optional millisecond field: absent or `null` is `None`, a whole
/// number is the value, anything else is malformed.
fn millis(
  json : Json,
  key : String,
  path : @json.JsonPath,
) -> Int64? raise @json.JsonDecodeError {
  guard json is Object(fields) else { return None }
  match fields.get(key) {
    None | Some(Null) => None
    Some(Number(value, ..)) if !value.is_inf() && value == value.floor() =>
      Some(value.to_int64())
    Some(_) =>
      raise JsonDecodeError(
        (
          path.add_key(key),
          "JournalEntry: \{key} must be a whole number of milliseconds",
        ),
      )
  }
}

///|
/// The journal file is damaged somewhere other than its final line. A torn
/// TAIL is expected crash damage and is repaired on load; mid-file
/// corruption means the append-only contract was broken by something else
/// and must not be silently dropped.
pub suberror JournalCorrupted {
  JournalCorrupted(path~ : String, line~ : Int)
}

///|
pub extend JournalCorrupted with Show::{to_string, output}

///|
pub impl Show for JournalCorrupted with fn output(self, logger) {
  let JournalCorrupted(path~, line~) = self
  logger.write_string("journal \{path} is corrupt at line \{line}")
}

///|
/// The replay journal: prior-run entries consumed by WORK-IDENTITY match
/// as this run re-executes, plus an append-only record of this run's live
/// outcomes. Replay rules:
///
/// - a matching `Finished` entry replays its value — the work is not
///   re-paid, and neither the launch allowance nor `tokens_spent` is
///   charged (historical spend lives here, not in the fresh account);
/// - a matching `Skipped` entry replays as the same refusal — a human
///   declined this call once, and resume must not override that decision;
/// - any other failure does NOT replay: getting past it is what resume is
///   FOR, so the call runs live again (and consumes fresh launch
///   allowance — size `max_calls` with re-attempts in mind).
///
/// Identity is the call's work content — kind, input, max_steps, schema,
/// and the workflow's replay scope — never the display label, and never
/// the phase or time an entry records. Duplicate identical calls are
/// intentional samples (three identical verifiers), so matching consumes
/// entries as a multiset: each replay consumes one entry, in file order,
/// and only LIVE outcomes are recorded — replays are never re-appended, so
/// entry counts stay honest across any number of resume generations.
///
/// A file-backed journal assumes ONE writing workflow process per path:
/// appends are serialized within the process, not across processes.
struct Journal {
  prior : Array[JournalEntry]
  consumed : Array[Bool]
  path : String?
  recorded : Array[JournalEntry]
  write_lock : @async.Mutex
}

///|
/// A journal with no backing file: `prior` seeds replay (empty by
/// default, copied — later mutation of the argument cannot skew the
/// consumption bookkeeping), live outcomes accumulate in `recorded`. The
/// test-and-embed constructor.
pub fn Journal::in_memory(prior? : Array[JournalEntry] = []) -> Journal {
  let prior = prior.copy()
  {
    prior,
    consumed: Array::make(prior.length(), false),
    path: None,
    recorded: [],
    write_lock: Mutex(),
  }
}

///|
/// Open (or start) a file-backed journal: an append-only JSONL file, one
/// entry per line, accumulated across every generation of the run. A
/// missing file is an empty journal.
///
/// Crash honesty: a torn TAIL — an unparsable or undecodable final line,
/// or a final line missing its newline — is the signature of dying
/// mid-append. The damaged suffix is dropped from replay AND repaired on
/// disk (atomic rewrite-and-rename), so the next generation's appends
/// land on a clean boundary instead of concatenating onto torn bytes.
/// Damage anywhere else raises `JournalCorrupted`. Lines are split at the
/// byte level before UTF-8 decoding, so a tail torn mid-codepoint cannot
/// poison the healthy prefix.
pub async fn Journal::load(path : String) -> Journal {
  let prior : Array[JournalEntry] = []
  if @fs.exists(path) {
    let bytes = @fs.read_file(path).binary()
    let segments : Array[(Int, Int)] = []
    let mut start = 0
    for index in 0..<bytes.length() {
      if bytes[index] == b'\n' {
        segments.push((start, index))
        start = index + 1
      }
    }
    let terminated = start == bytes.length()
    if !terminated {
      segments.push((start, bytes.length()))
    }
    // Repair is a TRUNCATION to the last healthy line, never a
    // re-encoding: every byte before the damage is kept as written, so
    // metadata lines and fields this version does not read survive into
    // the next generation. An unterminated final line needs the repair
    // even when its content parses: the next append would otherwise fuse
    // two entries.
    let mut needs_repair = !terminated
    let mut keep = bytes.length()
    for index, segment in segments {
      let (from, to) = segment
      let parsed : Result[JournalEntry?, Error] = Ok(parse_line(bytes[from:to])) catch {
        error => Err(error)
      }
      match parsed {
        Ok(Some(entry)) => prior.push(entry)
        Ok(None) => ()
        Err(_) if index == segments.length() - 1 => {
          needs_repair = true
          keep = from
        }
        Err(_) => raise JournalCorrupted(path~, line=index + 1)
      }
    }
    if needs_repair {
      let tmp = path + ".repair"
      @fs.write_file(tmp, bytes[0:keep])
      if keep > 0 && bytes[keep - 1] != b'\n' {
        @fs.write_file(tmp, b"\n", append=true, create_mode=OpenOrCreate)
      }
      @fs.rename(tmp, path, replace=true)
    }
  }
  {
    prior,
    consumed: Array::make(prior.length(), false),
    path: Some(path),
    recorded: [],
    write_lock: Mutex(),
  }
}

///|
/// One line's entry; `None` for a blank line (also covers the `\r` a CRLF
/// writer leaves behind) and for a v1 line that carries no entry. Raises
/// on undecodable bytes, unparsable JSON, or an unknown line shape — the
/// caller decides whether that is a torn tail or corruption.
fn parse_line(segment : BytesView) -> JournalEntry? raise {
  let text = @utf8.decode(segment).trim()
  if text.is_empty() {
    return None
  }
  // Schema-versioned envelope: the storage format is an evolvable
  // contract of its own, never derived codec output blessed by accident.
  // A v1 line WITHOUT an entry is metadata for other readers (a tool's
  // annotation, a future plan header): replay skips it, repair keeps it.
  match @json.parse(text.to_owned()) {
    { "v": Number(1, ..), "e": entry, .. } => Some(@json.from_json(entry))
    { "v": Number(1, ..), .. } => None
    _ => fail("journal line is not a v1 line")
  }
}

///|
/// This run's live outcomes, in completion order (a copy — the journal's
/// own bookkeeping cannot be skewed through it).
pub fn Journal::recorded(self : Journal) -> Array[JournalEntry] {
  self.recorded.copy()
}

///|
/// The prior-run entries replay draws from, in file order (a copy).
pub fn Journal::prior(self : Journal) -> Array[JournalEntry] {
  self.prior.copy()
}

///|
/// Two calls describe the same WORK: everything but the display label.
fn same_work(a : AgentCall, b : AgentCall) -> Bool {
  a.kind == b.kind &&
  a.input == b.input &&
  a.max_steps == b.max_steps &&
  a.scope == b.scope &&
  a.schema == b.schema
}

///|
/// CLAIM the next replay candidate for one call, consuming it. Purely
/// synchronous — no suspension separates lookup from consumption, so
/// concurrent identical calls each claim a distinct entry. Selection
/// prefers successes (in file order); only when no unconsumed success
/// remains does the EARLIEST recorded skip stand in. The caller walks
/// candidates: a candidate its validator vetoes stays consumed, and the
/// next claim gets the next candidate — a stale generation must never
/// mask the valid one recorded after it. `release` rolls a claim back
/// when validation UNWINDS (cancellation, registry error): the entry was
/// neither served nor rejected, so it stays available.
fn Journal::claim(self : Journal, call : AgentCall) -> (Int, AgentOutcome)? {
  let mut skip_slot : Int? = None
  for index, entry in self.prior {
    if self.consumed[index] || !same_work(entry.call, call) {
      continue
    }
    match entry.outcome {
      Finished(..) => {
        self.consumed[index] = true
        return Some((index, entry.outcome))
      }
      DidNotFinish(failure=Skipped, ..) =>
        if skip_slot is None {
          skip_slot = Some(index)
        }
      DidNotFinish(..) => ()
    }
  }
  // No success to replay: a recorded human refusal still stands; any
  // other failure yields a live re-attempt.
  if skip_slot is Some(index) {
    self.consumed[index] = true
    return Some((index, self.prior[index].outcome))
  }
  None
}

///|
/// Roll back a claim whose validation unwound before deciding.
fn Journal::release(self : Journal, slot : Int) -> Unit {
  self.consumed[slot] = false
}

///|
/// Append one live outcome — to memory always, and through to the backing
/// file when there is one. Appends are serialized behind a mutex: one
/// entry's line may take several syscalls to write, and concurrent agent
/// completions must interleave at line granularity, never byte.
async fn Journal::record(self : Journal, entry : JournalEntry) -> Unit {
  self.recorded.push(entry)
  if self.path is Some(path) {
    self.write_lock.acquire()
    defer self.write_lock.release()
    // OpenOrCreate, not the default CreateOrTruncate: append must never
    // wipe the generations already on disk.
    @fs.write_file(
      path,
      ({ "v": 1, "e": entry } : Json).stringify() + "\n",
      append=true,
      create_mode=OpenOrCreate,
    )
  }
}
