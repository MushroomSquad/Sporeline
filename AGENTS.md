# Instructions for AI Agents (Claude, Cursor, Codex, and others)

This file follows the [AGENTS.md](https://agents.md) convention — it's read by Codex CLI,
Cursor, and most other agentic coding tools. Claude Code additionally reads `CLAUDE.md`,
which points back here.

Before editing any code, read `README.md` (the full project guide: what/why/how, per
runtime, per CI system) and `docs/DECISIONS.md` (decision history — what was already
tried and rejected). Half of the "obvious improvements" here were already proposed and
rejected with an explanation — don't re-propose them without reading DECISIONS.md
section 6 first.

## What This Project Is

A CI-agnostic core (`ci <step>` in bash) + thin adapters for GitLab CI/CD Components,
GitHub Actions, and Jenkins. The same `ci` binary, baked into an image, is invoked the
same way from all three systems. `tools/generate.py` is a dev-time generator for GitLab
components from `core/runtimes/*/meta.yaml` — it takes no part in pipeline execution.

## Hard Invariants — Don't Break Without an Explicit User Request

- **Only bash/YAML/Groovy for logic.** No Python (or any other language) as step or
  pipeline-graph *runtime logic*. Python is allowed only as the dev-time generator
  (`tools/generate.py`) — it never runs inside a user's pipeline.
- **`templates/*.yml` is never hand-edited.** These are generated files
  (`python3 tools/generate.py` from `core/runtimes/*/meta.yaml`). Edit the source, then
  regenerate and verify with `--check`.
- **Graph logic (branches, retry, manual, conditions) lives in the consumer's
  YAML/Groovy**, not in the generator and not in `core/`. The core only implements step
  *behavior*. This is a deliberate architectural decision — a "logic constructor" in the
  generator was already tried and rolled back, see `docs/DECISIONS.md` section 6.1.
- **Do not touch the `trap "rm -rf '$HCI_TMP'" EXIT` line in `core/lib/dispatch.sh`.**
  An attempt to extend it to `INT TERM HUP` was empirically verified (`kill -TERM` on a
  live process) to be a regression: secrets/SSH keys aren't reliably cleaned up on
  signal-based job termination. This affects every step, not just new ones.
- **Secrets never land in argv or a URL.** The project's pattern: a `GIT_ASKPASS` script
  for HTTPS tokens (never embed them in the URL), `credential.helper=` reset before git
  operations, `curl -K -` (stdin config) instead of `-H` in argv for Authorization
  headers. See `core/steps/cd-bump.sh` and `cd-notify.sh` as the reference — they carry
  "why" comments right next to the code; don't reintroduce bugs already fixed there
  (the case-insensitive URL gate, the askpass dual-prompt contract, etc.).

## Required Verification After Changes

```bash
# Syntax of any changed shell file
bash -n core/steps/<file>.sh

# Core unit tests (bats)
bats tests/unit/*.bats
# Integration tests — if you touched cd:bump/cd:notify or anything network/git-based
bats tests/integration/*.bats

# If you touched tools/generate.py or core/runtimes/*/meta.yaml
uv run --with pyyaml python3 tools/generate.py --check
uv run --with pyyaml python3 -m unittest discover -s tests/unit -p 'test_*.py'
```

`generate.py --check` must be clean before considering a task done, if any `meta.yaml` or
the generator itself was changed. `templates/*.yml` is regenerated
(`python3 tools/generate.py`, no `--check`), never hand-edited.

## Where Things Live

```
core/bin/ci                  # entrypoint
core/lib/dispatch.sh          # step dispatcher, configuration cascade
core/lib/*.sh                 # retry, manifest, tls, log, config, ci-env
core/steps/*.sh                # shared steps (image-*, sonar, cd-bump, cd-notify, ...)
core/runtimes/<rt>/
  meta.yaml                     # versions/service_types/steps — source of truth for the generator
  lib.sh                         # step::build/test/... for the runtime
templates/*.yml                # GitLab CI/CD Components (generated, never hand-edited)
adapters/{gitlab,github,jenkins}/  # thin adapters, call `ci <step>`
tools/generate.py              # generator for templates/*.yml + wrappers + schema.yaml + e2e
tests/unit/*.bats               # unit tests for steps/libraries (git/network mocked)
tests/integration/*.bats        # against a real git repository (file://)
docs/pipeline.md                # pipeline-logic construction, full CD edge cases
docs/DECISIONS.md               # what was tried and rejected — read before "improving" things
```

The full architecture, plus a table per runtime and per CI system, is in `README.md`.

## Style

- Code comments explain non-obvious "why", not "what". The existing code is full of such
  comments with the rationale for subtle decisions — that's the project's working memory,
  not noise; don't strip them during a refactor without a reason.
- Don't add dependencies/abstractions beyond what's needed. `jq`/`yq` are already
  fundamental core dependencies (parsing `.ci.yaml`, the artifact manifest, YAML edits in
  `cd:bump`) — not a cause for alarm, but also not a precedent for adding more without
  need.
- Before "fixing an obvious bug" in `core/lib/dispatch.sh`, `core/lib/config.sh`, or in
  security-sensitive steps (`cd-bump.sh`, `cd-notify.sh`) — check whether the current
  behavior is intentional (look for a comment next to the line).
