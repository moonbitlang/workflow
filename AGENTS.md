# Agents guide

This is a [MoonBit](https://docs.moonbitlang.com) module: `moonbitlang/workflow`.

- Packages live one per directory with a `moon.pkg`; blackbox tests end in
  `_test.mbt`. The core package (this directory) never spawns a process —
  only `spawn/` does, and `viz/` and `examples/scout/` are executables.
- The wire contract every engine must speak is `docs/child-contract.md`.
  Changing anything the `spawn` package reads or writes on the wire is a
  contract change: update that document in the same change, and bump the
  `workflow_contract` major when the change is not additive.
- Gates: `just check` and `just test` (both `native` and `wasm` targets).
  Finish with `just tidy` (`moon info && moon fmt`) and review the
  `pkg.generated.mbti` diff — an unchanged interface means an internal
  refactor.
- `shim/` is the shim side of the contract; `shim/claude` and `shim/codex`
  are process shims around those CLIs. Their dialect tests are recorded
  JSONL lines: when a CLI changes its output format, update the fixture
  AND the classifier together, never one of them.
- The `.mbtx` scripts under `examples/` are not part of `moon test`: they
  bind the PUBLISHED module by version in their import header, so bump
  those pins when releasing.
