# Instructions for Claude Code

The full instructions are in [AGENTS.md](AGENTS.md) — read it in full before making
changes. This file is only a pointer plus a couple of Claude Code-specific notes.

Short version from AGENTS.md: start with `README.md` (the full guide) and
`docs/DECISIONS.md` (what was rejected and why), then make changes. `templates/*.yml` is
generated, never hand-edited. No Python or any other language as pipeline logic — only
bash/YAML/Groovy. `core/lib/dispatch.sh`, the `trap ... EXIT` line — don't touch it (see
AGENTS.md for why).

After making changes, the verification commands from AGENTS.md (`bash -n`, `bats`,
`tools/generate.py --check`, the Python unit tests) are mandatory before considering a
task complete.
