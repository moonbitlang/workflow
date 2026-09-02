default:
    just --list

# Type-check both supported targets under the warning policy and verify formatting.
check:
    moon check --target native --deny-warn
    moon check --target wasm --deny-warn
    moon fmt --check

# Run the unit, contract (scripted `sh` children), and README doc tests.
test:
    moon test --target native
    moon test --target wasm

# Refresh generated interfaces and formatting after a change.
tidy:
    moon info
    moon fmt

# Render a journal to HTML (add --watch to follow a running workflow).
viz *args:
    moon run viz -- {{ args }}

# Build the Claude Code and Codex process shims (native).
shims:
    moon build shim/claude --target native
    moon build shim/codex --target native
