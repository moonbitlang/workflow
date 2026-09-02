# Cross-engine review of e2bdb1a against HEAD~6

Court: claude, codex, explore. 2 finding(s) raised · 0 confirmed · 2 uncertain · 0 refuted

## Uncertain

### shim/shim.mbt:52 — Missing `input` field on a valid v1 envelope is misreported as an unsupported version (medium, raised by claude)

When `workflow_contract` is exactly 1 but the `input` key is absent (e.g. `{"workflow_contract": 1, "kind": "explore"}`), the first match arm fails to match only because `input` is missing, and control falls through to the second arm, which reports the version as unsupported even though version 1 is exactly what was supplied and is supported. This contradicts the function's own doc comment ("Accepts the v1 envelope ... or a bare input ... anything else is a typed refusal") which treats version-rejection and input-validation as separate failure modes, and sends a caller debugging a malformed request down the wrong path (they'd conclude the contract version needs bumping, when the real problem is a missing `input` field).

```
{ "workflow_contract": Number(1, ..), "input": input, .. } => { ... }
    { "workflow_contract": Number(version, ..), .. } =>
      return Err("unsupported workflow_contract version \{version}")
```

Verifier (codex): verifier failed: agent 'verify:shim/shim.mbt:52' failed: codex: You've hit your usage limit for GPT-5.3-Codex-Spark. Switch to another model now, or try again at 11:36 PM.

### shim/shim.mbt:48 — Wrong-typed max_steps silently treated as "no ceiling" instead of erroring (medium, raised by claude)

The adjacent comment states the explicit design intent that a malformed `max_steps` must never fall through to "no ceiling", citing a prior cross-engine review finding that fixed exactly this bug for fractional numbers. But the fix only covers the case where `max_steps` is a JSON Number; if `max_steps` is present with any other JSON type (string, bool, array, object), the outer match's `_ => None` arm silently treats it as absent, reintroducing the same failure mode (a request meant to cap steps runs uncapped) for a different malformed-value shape.

```
let max_steps = match json {
        { "max_steps": Number(steps, ..), .. } =>
          match integral(steps) {
            Some(steps) => Some(steps)
            None => return Err("shim input max_steps must be an integer")
          }
        _ => None
      }
```

Verifier (codex): verifier failed: agent 'verify:shim/shim.mbt:48' failed: codex: You've hit your usage limit for GPT-5.3-Codex-Spark. Switch to another model now, or try again at 11:36 PM.

## Cost

| engine | calls | steps | prompt tokens | completion tokens |
| --- | ---: | ---: | ---: | ---: |
| claude | 2 | 11 | 450003 | 41810 |
| codex | 4 | 2 | 0 | 0 |
| explore | 2 | 10 | 210149 | 68373 |

8 live call(s), 0 replayed, 770335 fresh tokens.
