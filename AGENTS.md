# Agents guide

This is a [MoonBit](https://docs.moonbitlang.com) module: `moonbitlang/workflow`.

- Packages live one per directory with a `moon.pkg`; blackbox tests end in
  `_test.mbt`. The core package (this directory) never spawns a process —
  only `spawn/` and `shim/` do; `viz/` and `examples/scout/` are executables.
- The wire contract every engine must speak is `docs/child-contract.md`.
  Changing anything the `spawn` package reads or writes on the wire is a
  contract change: update that document in the same change, and bump the
  `workflow_contract` major when the change is not additive.
- Gates: `just check` and `just test` (both `native` and `wasm` targets).
  Finish with `just tidy` (`moon info && moon fmt`) and review the
  `pkg.generated.mbti` diff — an unchanged interface means an internal
  refactor.
- `moon ide analyze` annotates every exported item with how many
  dependents use it. A `pub` nothing uses is either surface to drop —
  an executable (`shim/claude`, `shim/codex`, `viz`, `examples/scout`)
  exports nothing anyone can import — or public on purpose for a caller
  outside this repository, in which case it goes in that package's
  `exports.mbt` with a doc comment naming that caller. The tool respects
  the file and marks those `in exports.mbt`, so the report stays a list
  of real findings. A symbol that cannot name its outside caller belongs
  private.
- `shim/` is the shim side of the contract; `shim/claude` and `shim/codex`
  are process shims around those CLIs. Their dialect tests are recorded
  JSONL lines: when a CLI changes its output format, update the fixture
  AND the classifier together, never one of them.
- The `.mbtx` scripts under `examples/` are not part of `moon test`: they
  bind the PUBLISHED module UNVERSIONED, so every run takes the latest
  release. An interface change therefore reaches them the moment it is
  published, not when someone remembers a pin — a release that breaks an
  example must fix it in the same change. `moon run <script>` is the only
  thing that compiles one: `moon check` takes the path as a directory
  filter and silently checks nothing.
