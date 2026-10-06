[English](DECISIONS.md) | [Русский](DECISIONS.ru.md)

# Decisions and Design History

This document records the agreements from the working session that rewrote the CI
templates (`templates-master`). It's not a commit changelog, but a record of **what was
decided and why**, including the paths that were rejected.

Related docs:

- [pipeline.md](pipeline.md) — how to customize pipeline logic today
- [../README.md](../README.md) — quick start
- [../adapters/README.md](../adapters/README.md) — GitLab / GitHub / Jenkins

---

## 1. The Original Request

- Take apart the old GitLab templates, remove agent instructions (`AGENTS.md`, `.cursor/`).
- Expand language support (incl. Python), optimize, add more customization and
  variability.
- Greenfield is fine; GitHub/Jenkins ports to follow later.
- The core is bash (`bash_lib` → `core/`), baked into images (`/opt/ci`).
- The platform's artifact contract is open for revision.

Later: finish the adapters, explain pipeline customization; questions about UI stages,
branching, retry, logical operators → an attempt at a "full construction kit" → rolled
back.

---

## 2. Core Architecture (Accepted)

| Decision | Choice | Why |
|---------|--------|--------|
| Core language | Bash CLI `ci <step>` | Bash was already in the YAML; it ships inside the image; no need for a separate Go/Python runtime in every job |
| Core delivery | An image with `/opt/ci`, tag `…-ci{VERSION}` | GitLab's `include: project` doesn't pull in neighboring scripts |
| Env prefix | `HCI_*` (not `CI_*`) | Avoid colliding with GitLab's own variables |
| Config | CLI → env → `.ci.yaml` → runtime defaults → `core/defaults.env` | Predictable priority |
| Soft failure | exit **78** | Tests/linters/scans don't fail the pipeline at `strict=false`; adapters map it to allow_failure / warning / unstable |
| Skip | exit **86** (where used) | An explicit step skip |
| Profiles | `HCI_PROFILE` (e.g. maven/quarkus) | Variability within a runtime |
| Manifest | `hci-artifacts/artifacts.json` v2 | A single artifact contract |
| Core-level retry | `retry.sh` for network/push | Not to be confused with CI's own job-level retry |

**Adapters** are thin: only the job graph and the `ci <step>` call.

- GitLab: CI/CD components in `templates/`
- GitHub: composite + reusable workflow
- Jenkins: shared library `hci` / `hciPipeline`

---

## 3. The `tools/generate.py` Generator (Accepted, Narrow Role)

**Why it exists:** to avoid copy-pasting nearly identical GitLab components across ~10
runtimes (differences are image versions, cache, junit/coverage, the step list from
`meta.yaml`). Plus: the e2e matrix, image wrappers, `schema.yaml` (a flow/runtime
catalog).

**Why it's not needed for:** pipeline logic (branches, `when`, retry, OR/AND). The
generator makes no claim on this.

If hand-written YAML per runtime is acceptable, the generator can be removed; that
doesn't change the "logic lives in the project" model.

`templates/*.yml` is never hand-edited while the generator is alive — only `meta.yaml` +
`generate.py`.

---

## 4. Two Customization Layers (Accepted)

Separating what used to be conflated:

| Layer | Where | What |
|------|-----|-----|
| **Step behavior** | `.ci.yaml`, `HCI_*_CMD`, hooks, `strict` | *how* to build / test / publish |
| **Pipeline logic** | the **project's** YAML/Groovy | *when* a job exists: branches, sources, changes, retry, manual, OR/AND |

Step toggles in component inputs (`test: false`, `sonar: true`) are a convenience, not a
replacement for `rules`.

---

## 5. Pipeline Logic = Project YAML (Accepted)

Priority: **maximum customizability and configurability**.

- The logic construction kit is **plain GitLab CI YAML** in the service repository
  (`workflow:rules`, overriding `build`/`test`/`image:publish` with your own
  `rules`/`retry`/`needs`).
- GitHub — `on:` / `if:` in the calling workflow (or a fork of `pipeline.yml`).
- Jenkins — `when {}`, `retry()`, `input` in the Jenkinsfile / Groovy.

The template's default is minimal: enabled + `service_type` + publish on tag. Anything
more complex is an override in the project. Details: [pipeline.md](pipeline.md).

**Templates + reuse** only increase customization if the template is **thin** (steps/`ci`
are reused, not a monolithic "smart" pipeline). A thick template with baked-in policy cuts
customization instead.

---

## 6. Rejected / Rolled Back

### 6.1. A "Full Construction Kit" Inside the Generator

This was built, then **removed**:

- inputs: `branches`, `except_branches`, `pipeline_sources`, `changes`, `job_retry`,
  `publish_mode`
- a "smart" `rules()` with `$HCI_BRANCHES` / an OR-list keyed on `publish_mode`
- a `constructor` block in `schema.yaml` for UI widgets
- parity for these presets across GitHub/Jenkins

**Why rejected:** this isn't a YAML construction kit, it's Python plus intermediate
variables; customization is limited to presets; and it's unclear what UI would even
consume it.

### 6.2. A Platform Web UI / "Showcase"

`schema.yaml` as a contract for drawing a form in some platform is **not a goal** of the
current design. We're not designing or promising a UI. The `schema.yaml` catalog may
still exist for external flow/runtime consumers — without a constructor block and without
being tied to any "construction kit".

### 6.3. A Free-Form Expression DSL in Inputs

Not doing this: user-supplied `||`/`if` strings via component inputs. Logic belongs in
native CI YAML / Groovy.

### 6.4. Job Retry and Branch Policy in the Bash Core

The policy of "which branches this runs on" and job-level retry belong to CI YAML/Groovy,
not `core/`. The core only keeps network-level `retry.sh` and normalizes `HCI_BRANCH` /
`HCI_IS_MR` as env vars.

---

## 7. Old World → New World (Meaning Migration)

| Was | Became |
|------|--------|
| `include: project: … Maven.gitlab-ci.yml` | `include: component: …/maven@tag` |
| `STAGE_TEST` and others | the `test:` input / a `rules` override |
| `SERVICE_TYPE` | `service_type` |
| `JDK_VERSION` / runtime version vars | `runtime_version` |
| Logic split across `default/` + `buildah/` + runtime YAML chunks | a graph in the component; behavior in `core/` |
| Inline shell in `script:` | `ci <step>` from the image |

No automatic migration of consumer `.gitlab-ci.yml` files was done — only the meaning
mapping.

---

## 8. What's in the Repository Now (Model Snapshot)

```
core/                 # ci, lib, steps, runtimes/*/meta.yaml
templates/            # GitLab components (from generate.py)
adapters/
  gitlab/             # docs; the yml files live in templates/
  github/             # action + pipeline.yml
  jenkins/            # vars/hci.groovy, hciPipeline.groovy
  common/run-step.sh
tools/generate.py     # DRY for runtimes + e2e + wrappers + schema
docs/pipeline.md      # how to write logic in the project
docs/DECISIONS.md     # this file
images/               # Containerfiles, CI wrappers
tests/                # bats, fixtures, e2e include
```

---

## 9. Short Answers to Session Questions

**"Stages don't show up in the web UI?"**
The templates do have GitLab stages (`stage_*` inputs). There's no separate constructor
UI, and that's not a goal.

**"Branching / retries / logical operators?"**
In the project's YAML (or Groovy). Not in the generator.

**"Why does the generator exist?"**
Only to DRY up nearly-identical runtime components and for auxiliary generation. Not for
pipeline logic.

**"Would template reuse increase customization?"**
Only with thin templates and explicit extension points. Otherwise — the opposite.

---

## 10. Principles Going Forward

1. Thin adapter, thick step core.
2. Pipeline logic lives in the user's CI language (YAML / Groovy).
3. Don't hide run policy behind "smart" inputs.
4. Don't promise a platform UI from this repository.
5. The generator is an optional convenience, not the source of truth for rules.
