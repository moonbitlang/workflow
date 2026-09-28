///|
/// What a run cost, in the contract's counters, plus the CLI's own price
/// when it states one. A dialect that learned nothing reports no `Usage`
/// at all — an unknown cost is never a zero one.
pub struct Usage {
  /// Everything the model read: fresh input and cache reads and writes.
  prompt_tokens : Int
  completion_tokens : Int
  cache_hit_tokens : Int
  cache_miss_tokens : Int
  cost_usd : Double?
} derive(Eq, Debug)

///|
/// A usage reading from its parts; `cost_usd` only when the CLI stated it.
pub fn Usage::Usage(
  prompt_tokens~ : Int,
  completion_tokens~ : Int,
  cache_hit_tokens~ : Int,
  cache_miss_tokens~ : Int,
  cost_usd? : Double,
) -> Usage {
  {
    prompt_tokens,
    completion_tokens,
    cache_hit_tokens,
    cache_miss_tokens,
    cost_usd,
  }
}

///|
/// Two readings together. The price of the sum is known only when both
/// prices are: a sum that left one out would under-report it.
pub fn Usage::add(self : Usage, other : Usage) -> Usage {
  {
    prompt_tokens: self.prompt_tokens + other.prompt_tokens,
    completion_tokens: self.completion_tokens + other.completion_tokens,
    cache_hit_tokens: self.cache_hit_tokens + other.cache_hit_tokens,
    cache_miss_tokens: self.cache_miss_tokens + other.cache_miss_tokens,
    cost_usd: match (self.cost_usd, other.cost_usd) {
      (Some(left), Some(right)) => Some(left + right)
      _ => None
    },
  }
}

///|
/// How a shim run ended: the result-file statuses a shim can reach
/// (`docs/child-contract.md` §3). The engine-side statuses a CLI shim
/// cannot observe (`context_yield`, `aborted`) have no variant.
pub(all) enum Status {
  /// The CLI finished; the payload is the report, the result's `output`.
  Completed(Json)
  /// The CLI exited cleanly without an answer.
  NoReport
  /// The step ceiling stopped the run.
  MaxStepsExhausted
  /// The parent cancelled the run by closing stdin.
  Interrupted(String)
  /// The run could not finish: why.
  Failed(String)
} derive(Eq, Debug)

///|
/// Everything a shim reports about one run: how it ended, what it cost when
/// the CLI said, and how many steps the dialect counted.
struct ShimResult {
  status : Status
  usage : Usage?
  steps : Int?
} derive(Eq, Debug)

///|
/// A result from its parts. Omit `usage` when the CLI reported none, and
/// `steps` when the run never got to count any.
pub fn ShimResult::ShimResult(
  status : Status,
  usage? : Usage,
  steps? : Int,
) -> ShimResult {
  { status, usage, steps, }
}

///|
/// The result document answering request `request_id`, as `serve` writes
/// it: `usage` and `steps` only when known, `total_tokens` derived.
pub fn ShimResult::to_json(self : ShimResult, request_id~ : String) -> Json {
  let (status, output, reason) : (String, Json?, String?) = match self.status {
    Completed(report) => ("completed", Some(report), None)
    NoReport => ("no_report", None, None)
    MaxStepsExhausted => ("max_steps_exhausted", None, None)
    Interrupted(why) => ("interrupted", None, Some(why))
    Failed(why) => ("failed", None, Some(why))
  }
  let fields : Map[String, Json] = {
    "version": 1,
    "request_id": Json(request_id),
    "status": Json(status),
  }
  if output is Some(output) {
    fields["output"] = output
  }
  if reason is Some(reason) {
    fields["reason"] = Json(reason)
  }
  if self.usage is Some(usage) {
    let counters : Map[String, Json] = {
      "prompt_tokens": Json(usage.prompt_tokens),
      "completion_tokens": Json(usage.completion_tokens),
      "total_tokens": Json(usage.prompt_tokens + usage.completion_tokens),
      "prompt_cache_hit_tokens": Json(usage.cache_hit_tokens),
      "prompt_cache_miss_tokens": Json(usage.cache_miss_tokens),
    }
    if usage.cost_usd is Some(cost) {
      counters["cost_usd"] = Json(cost)
    }
    fields["usage"] = Json::object(counters)
  }
  if self.steps is Some(steps) {
    fields["steps"] = Json(steps)
  }
  Json::object(fields)
}

///|
/// Write the result file so that a reader sees either no file or the whole
/// result: into a uniquely named sibling, created exclusively so no other
/// writer's file is ever touched, then renamed over `path`. A failure after
/// the sibling exists removes it.
async fn write_result(
  path : String,
  request_id : String,
  result : ShimResult,
) -> Unit {
  let text = "\{result.to_json(request_id~).stringify()}\n"
  let sibling = "\{path}.\{nonce()}.tmp"
  let file = @fs.open(sibling, mode=WriteOnly, create_mode=CreateNew)
  errdefer (@fs.remove(sibling) catch { _ => () })
  {
    defer file.close()
    file.write(text)
  }
  @fs.rename(sibling, path, replace=true)
}

///|
/// A name part no other writer is likely to pick: platform entropy when
/// there is some, the clock otherwise. Exclusive creation, not this, is
/// what keeps two writers apart.
fn nonce() -> String {
  guard @env.rand(8) is Some(bytes) else { return "\{@env.now()}" }
  let digits = "0123456789abcdef"
  let hex = StringBuilder()
  for byte in bytes {
    hex.write_char(digits[byte.to_int() >> 4].unsafe_to_char())
    hex.write_char(digits[byte.to_int() & 15].unsafe_to_char())
  }
  hex.to_string()
}
