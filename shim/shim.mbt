///|
/// THE SHIM SIDE OF THE CHILD CONTRACT — what every process shim around a
/// foreign agent CLI needs, over contract transport 2 (the result file):
/// `serve` parses the shim's argv and the one request line the runner
/// writes, and writes the one result file; `run_cli` runs the CLI while
/// the parent's stdin-EOF cancel signal stays live. `shim/claude` and
/// `shim/codex` are the two dialects; this package knows no CLI.
///
/// What the observer decides after each CLI stdout line.
pub(all) enum Verdict {
  Continue
  Stop
} derive(Eq)

///|
/// The dot-callable form of the derived equality methods is a migration
/// convenience, not API: compare with `==` / `!=` (through the `Eq`
/// trait) instead.
#deprecated("Use == / != (the Eq trait) instead of the attached equal/not_equal method")
#doc(hidden)
pub extend Verdict with Eq::{equal, not_equal}

///|
/// How a CLI run ended, from the shim's side. `Cancelled` is the parent's
/// stdin EOF: the run is `interrupted`, and the parent is already winding
/// down. `Stopped` is the observer's own decision (a step ceiling).
/// `Failed` is a run that never got going — an unspawnable command, a
/// broken pipe.
pub(all) enum CliExit {
  Exited(Int)
  Stopped
  Cancelled
  Failed(String)
} derive(Eq)

///|
/// The dot-callable form of the derived equality methods is a migration
/// convenience, not API: compare with `==` / `!=` (through the `Eq`
/// trait) instead.
#deprecated("Use == / != (the Eq trait) instead of the attached equal/not_equal method")
#doc(hidden)
pub extend CliExit with Eq::{equal, not_equal}

///|
/// Run the CLI: spawn it with its stdin already at EOF (the prompt rides
/// argv; OUR stdin is the parent's cancel channel and is never the
/// CLI's), hand every stdout line to `observe`, and tear the CLI down when
/// the observer says `Stop` or the parent closes our stdin. stderr is
/// inherited, so the CLI's diagnostics reach the parent's stderr
/// untouched.
///
/// A `Stop`, and the parent's cancel, are GRACEFUL: the CLI gets
/// `stop_signal` (SIGINT, its own Ctrl-C path) and `stop_grace_ms` to
/// flush, and every line it prints meanwhile still reaches `observe` — a
/// CLI that reports usage only at the end of a turn can still get its cost
/// recorded on a capped or cancelled run. Then it is killed. Every error
/// path — an observer that raises, a broken pipe, the caller's
/// cancellation — closes the pipes and terminates the CLI before returning
/// or re-raising; the task group would reap it anyway, but not before the
/// caller had already been told.
///
/// `until_cancelled` returns when the parent cancels the run; by default
/// that is our stdin reaching EOF, the contract's cancel signal. A test,
/// whose stdin is not a parent's pipe, passes its own.
pub async fn run_cli(
  command~ : String,
  args~ : Array[String],
  cwd? : String,
  until_cancelled? : async () -> Unit = parent_closes_stdin,
  stop_grace_ms? : Int = 3_000,
  stop_signal? : @signal.Signal = @signal.SIGINT,
  observe~ : async (String) -> Verdict,
) -> CliExit {
  let cancelled : Ref[Bool] = { val: false, }
  let stopped : Ref[Bool] = { val: false, }
  let code : Ref[Int] = { val: 0, }
  let failure : Ref[String?] = { val: None, }
  try
    @async.with_task_group() <| group => {
      let (child_stdin, stdin_writer) = @process.write_to_process() catch {
        error => {
          failure.val = Some("shim pipes unavailable: \{error}")
          return
        }
      }
      // Cleanup lives in `defer`, not in `catch` arms: cancellation is a
      // signal that bypasses `catch` and unwinds only through `defer` /
      // `errdefer`. Closing a pipe and cancelling a process are idempotent,
      // so the deferred teardown also covers the explicit closes below.
      defer stdin_writer.close()
      let (stdout_reader, child_stdout) = @process.read_from_process() catch {
        error => {
          failure.val = Some("shim pipes unavailable: \{error}")
          return
        }
      }
      defer stdout_reader.close()
      let process = @process.spawn(
        group,
        command,
        args,
        inherit_env=true,
        stdin=child_stdin,
        stdout=child_stdout,
        cwd?=cwd.map(dir => dir.view()),
        // `cancel()` sends SIGINT first — the CLI's own Ctrl-C path, the
        // one it flushes on — and kills only after the grace.
        cancel_handler=@process.graceful_cancel(
          timeout=stop_grace_ms,
          signal=stop_signal,
        ),
        no_wait=true,
      ) catch {
        error => {
          failure.val = Some("cannot spawn \{command}: \{error}")
          return
        }
      }
      defer process.cancel()
      // EOF at once: the CLI must never wait on stdin for a prompt.
      stdin_writer.close()
      group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
        until_cancelled()
        cancelled.val = true
        process.cancel()
      }
      try {
        while stdout_reader.read_until("\n") is Some(line) {
          if observe(line) is Stop && !cancelled.val {
            stopped.val = true
          }
          if cancelled.val || stopped.val {
            break
          }
        }
        if cancelled.val || stopped.val {
          // Graceful: SIGINT now (again, after a cancel: idempotent), keep
          // listening through the grace so a final accounting line still
          // counts, then the handler kills.
          process.cancel()
          let _ = @async.with_timeout_opt(stop_grace_ms, () => {
            while stdout_reader.read_until("\n") is Some(late) {
              let _ = observe(late)
            }
          })
        } else {
          // Bounded: a CLI that closed stdout but lingers is torn down below.
          code.val = @async.with_timeout_opt(2_000, () => process.wait()).unwrap_or(
            -1,
          )
        }
      } catch {
        error => {
          if failure.val is None {
            failure.val = Some("shim run failed: \{error}")
          }
          return
        }
      }
    }
  catch {
    error =>
      if failure.val is None {
        failure.val = Some("shim run failed: \{error}")
      }
  }
  match failure.val {
    Some(reason) => Failed(reason)
    None if cancelled.val => Cancelled
    None if stopped.val => Stopped
    None => Exited(code.val)
  }
}

///|
/// The contract's cancel signal: the parent closing our stdin. The request
/// line is already read; only EOF is meaningful after it.
async fn parent_closes_stdin() -> Unit {
  while @stdio.stdin.read_until("\n") is Some(_) {

  }
}
