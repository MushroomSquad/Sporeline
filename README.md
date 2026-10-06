English | [Русский](README.ru.md)

# Hyperion CI

A CI-agnostic core (`ci <step>` in bash) plus thin adapters for GitLab CI/CD Components,
GitHub Actions and Jenkins shared library. The same `ci` binary, baked into the build
image, is invoked the same way from all three systems. YAML/Groovy only describe the job
graph.

Narrower details live in [docs/pipeline.md](docs/pipeline.md) (pipeline-logic construction,
full CD edge cases) and [docs/DECISIONS.md](docs/DECISIONS.md) (decision history: what was
tried and rejected, and why).

## Contents

1. [What This Is and Why](#1-what-this-is-and-why)
2. [How It Works (Architecture)](#2-how-it-works-architecture)
3. [Three Usage Levels — With Examples](#3-three-usage-levels--with-examples)
4. [Every Runtime](#4-every-runtime)
5. [Every CI/CD System](#5-every-cicd-system)
6. [CD: bump and notify — on every CI system](#6-cd-cdbump-and-cdnotify--on-every-ci-system)
7. [Configuration Reference](#7-configuration-reference)

---

## 1. What This Is and Why

**What.** A CI-agnostic core (`ci <step>` in bash) plus thin adapters for GitLab CI/CD
Components, GitHub Actions and Jenkins shared library. The same `ci` binary, baked into
the build image, is invoked the same way from all three systems.

**Why not "one big pipeline in YAML".** Three recurring problems in typical CI templates:
(1) build logic is smeared across `script:` blocks and copy-pasted between runtimes with
small drifts; (2) pipeline "constructors" in generator scripts turn into a DSL on top of a
DSL — presets instead of real flexibility; (3) switching from one CI system to another
means rewriting all the logic from scratch. The fix: move step *behavior* (how to build,
test, publish) into a bash core, and keep graph *logic* (when a step runs — branches,
retry, manual, conditions) in each CI system's native language — GitLab YAML, GitHub
Actions YAML, Jenkins Groovy. The detailed rationale for each decision, including what was
tried and rejected (a full logic constructor in the generator, a platform UI, a free-form
DSL in inputs) — in [docs/DECISIONS.md](docs/DECISIONS.md).

**How (in one paragraph).** `ci <step>` is a dispatcher (`core/bin/ci` → `core/lib/dispatch.sh`)
that finds `step::<name>` in `core/steps/*.sh` or `core/runtimes/<rt>/lib.sh`, builds the
configuration from a priority cascade, and runs the step. Adapters (`templates/*.yml` for
GitLab, `adapters/github/*`, `adapters/jenkins/*`) are nothing but a job graph that calls
`ci <step>` with the right variables. `tools/generate.py` is a dev-time generator for
GitLab components from `core/runtimes/*/meta.yaml`, so the ~10 near-identical runtime
files don't have to be hand-copied; it takes no part in pipeline execution and contains no
branching logic.

---

## 2. How It Works (Architecture)

```
core/
  bin/ci                  # entrypoint: ci <step> [--key=value ...]
  lib/dispatch.sh          # finds step::<name>, runs runtime setup
  lib/config.sh            # configuration cascade, secret masking in logs
  lib/*.sh                 # retry, manifest, tls, log, ci-env (platform normalization)
  steps/*.sh                # shared steps: image-build, image-scan, sonar, cd-bump, cd-notify, …
  runtimes/<rt>/
    meta.yaml               # versions, service_types, steps, cache, reports — source of truth
    lib.sh                   # step::build / step::test / … for this runtime
    defaults.env             # runtime-specific defaults
  defaults.env              # core defaults

templates/*.yml              # GitLab CI/CD Components (generated from meta.yaml)
adapters/
  gitlab/README.md
  github/{action.yml,pipeline.yml}
  jenkins/vars/{hci.groovy,hciPipeline.groovy}
  common/run-step.sh         # shared soft-exit wrapper (code 78 → warning/unstable)

tools/generate.py            # generator for templates/*.yml, wrappers, schema.yaml, e2e matrices
```

**Configuration cascade** (higher wins): CLI `--key=value` → environment variables →
the project's `.ci.yaml` → `core/runtimes/<rt>/defaults.env` → `core/defaults.env`.
Every core key lives in the `HCI_*` namespace to avoid colliding with `CI_*` (GitLab),
`GITHUB_*`, `JENKINS_*`.

**Exit codes:** `0` — success; **78** — soft failure (a test/linter/scan with
`strict=false`): GitLab sees `allow_failure: exit_codes: [78]`, Jenkins marks it
`unstable`, GitHub shows a warning; **86** — explicit step skip (e.g. no sources for the
step).

**Artifact manifest** — `hci-artifacts/artifacts.json` (schema
`core/schema/artifacts.v2.json`), written only through `manifest::add`, read by steps like
`cd:bump` (image digest) and checked with `ci manifest:validate`.

**Core version**: the build wrapper image tag matches `core/VERSION` (suffix `-ci1.0.0`) —
bumping the core updates every image at once, with no manual per-runtime tag sync.

---

## 3. Three Usage Levels — With Examples

### Level 1 — quick start with a ready-made pipeline

Include one component, pick a runtime and `service_type`. The whole graph (build → test →
image:build → image:scan → image:publish, lint/sonar/deps:scan to taste) is already
inside.

```yaml
# .gitlab-ci.yml
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/maven@$CI_COMMIT_SHA
    inputs:
      runtime_version: "21"
      service_type: image
```

### Level 2 — customizing the ready-made pipeline

Toggle steps via inputs, pass behavior parameters via `.ci.yaml` / `HCI_*`, and override
graph logic (`rules`, `needs`, `retry`, `when`) in the project's YAML — this is **not two
competing APIs**, but two independent layers: component inputs control the graph's
*composition*, `rules`/`retry`/`needs` in YAML control the *run conditions* of jobs that
already exist.

```yaml
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/maven@1.0.0
    inputs:
      runtime_version: "21"
      service_type: image
      sonar: true          # add the step to the graph
      publish: false        # remove the step from the graph

workflow:
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH =~ /^(main|develop)$/
    - if: $CI_COMMIT_TAG

test:
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
      changes: [src/**/*, pom.xml]
  retry:
    max: 2
    when: [runner_system_failure, stuck_or_timeout_failure]

image:publish:
  rules:
    - if: $CI_COMMIT_TAG
    - if: $CI_COMMIT_BRANCH == "main"
      when: manual
      allow_failure: true
```

The step's own behavior (build command, hooks, registries) is configured separately, via
`.ci.yaml` or `HCI_*` — see [§7](#7-configuration-reference). This split is described in
[DECISIONS.md §4](docs/DECISIONS.md#4-two-customization-layers-accepted).

### Level 3 — a custom graph from individual components

For non-typical combinations (test without publish, several tests with different
parameters, lint in parallel with build) — granular components, one job per file:

```yaml
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/maven-build@$CI_COMMIT_SHA
    inputs:
      runtime_version: "21"
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/maven-test@$CI_COMMIT_SHA
    inputs:
      runtime_version: "21"

# Dependencies and conditions — set manually, one block per job
test:
  needs: [build]
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
```

Available granularly: `build`, `test`, `lint`, `publish`, `image:build`, `image:scan`,
`image:publish` for each runtime (where applicable). Analysis/scan steps (`deps:scan`,
`sonar`, `svace`, `appscreener`, `kcs`) and `cd:bump`/`cd:notify` stay bundle-only — at
level 2 they're already toggled by an input, so separate files for them aren't needed
(and would be a wasteful spend of GitLab's scarce per-project component limit — see §5).
Chained dependency: `image:scan`/`image:publish` require `image:build` in the same
`job_prefix`, or `log::die` fires at step start with a clear diagnostic.

GitHub Actions and Jenkins equivalents — in [§5](#5-every-cicd-system).

---

## 4. Every Runtime

Common step list per runtime: `build`, `test` (where present), `lint` (where present),
`publish` (only `service_type: library`), `image:build`/`image:scan`/`image:publish`
(only `service_type: image`), plus the always-available optional `deps:scan`, `sonar`,
`svace`, `appscreener`, `kcs`, `cd:bump`, `cd:notify` (off by default except
`deps:scan`). Below is what's different per runtime: versions, `service_type`, special
inputs.

### bun

| | |
|---|---|
| **default_version** | `1` |
| **service_types** | `image`, `library` |
| **Notable** | Publishes packages to the npm registry when `service_type: library` |
| **Cache** | `bun.lock`, `bun.lockb`, `node_modules` |

```yaml
# GitLab
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/bun@1.0.0
    inputs: { runtime_version: "1", service_type: image }
```

### dotnet

| | |
|---|---|
| **default_version** | `100` (.NET 10.0) |
| **Available versions** | 3.1, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0 |
| **service_types** | `image`, `library` (nupkg to a nuget-hosted repo) |
| **Notable** | Svace analysis supported (`svace: true`) |

```yaml
# GitLab
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/dotnet@1.0.0
    inputs: { runtime_version: "80", service_type: image }
```

### go

| | |
|---|---|
| **default_version** | `125` (1.25) |
| **Available versions** | 1.22, 1.25 |
| **service_types** | `image` only; static binary, no library publish |
| **Notable** | Runtime image is `scratch` (minimal, no package-registry publish); `cobertura` coverage report |

```yaml
# GitLab
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/go@1.0.0
    inputs: { runtime_version: "125", service_type: image }
```

### gradle (Java)

| | |
|---|---|
| **default_version** | `21` |
| **Available versions** | 8, 11, 17, 21, 25 |
| **service_types** | `image`, `library` |
| **Notable** | JUnit + Jacoco reports out of the box; `build.gradle`/`gradle.lockfile` cached |

```yaml
# GitLab
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/gradle@1.0.0
    inputs: { runtime_version: "21", service_type: library }
```

### maven (Java)

| | |
|---|---|
| **default_version** | `21` |
| **Available versions** | 8, 11, 17, 21, 25 |
| **service_types** | `image`, `library` |
| **Profiles** | `profile: quarkus` — alternative build/package flow for Quarkus projects |
| **Notable** | JUnit (surefire+failsafe) + Jacoco; multi-module projects supported |

```yaml
# GitLab — plain Maven
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/maven@1.0.0
    inputs: { runtime_version: "21", service_type: image }

# GitLab — Quarkus profile
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/maven@1.0.0
    inputs: { runtime_version: "21", service_type: image, profile: quarkus }
```

### nodejs

| | |
|---|---|
| **default_version** | `22` |
| **Available versions** | 10, 12, 14, 16, 18, 20, 22 |
| **service_types** | `image`, `library` |
| **Notable** | npm, yarn or pnpm (corepack) — auto-detected from the lockfile; `build`/`test`/`lint` scripts come from `package.json` |

```yaml
# GitLab
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/nodejs@1.0.0
    inputs: { runtime_version: "22", service_type: image }
```

### php

| | |
|---|---|
| **default_version** | `83` (8.3) |
| **Available versions** | 7.3, 7.4, 8.0, 8.1, 8.2, 8.3 |
| **service_types** | `image` only |
| **Notable** | Composer + s2i (ubi-php); tests via PHPUnit, no `lint`/`publish` steps |

```yaml
# GitLab
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/php@1.0.0
    inputs: { runtime_version: "83", service_type: image }
```

### python

| | |
|---|---|
| **default_version** | `312` (3.12) |
| **Available versions** | 3.9, 3.11, 3.12, 3.13 |
| **service_types** | `image`, `library` (wheel/sdist to a pypi-hosted repo) |
| **Notable** | pip, uv, poetry or pdm — auto-detected; `service_type: image` packages a venv into the image |

```yaml
# GitLab
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/python@1.0.0
    inputs: { runtime_version: "312", service_type: library }
```

### rust

| | |
|---|---|
| **default_version** | `190` (1.90) |
| **service_types** | `image` (static binary in `scratch`), `library` (crate publish) |
| **Notable** | Cargo; the only toolchain version available today is 1.90 |

```yaml
# GitLab
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/rust@1.0.0
    inputs: { runtime_version: "190", service_type: image }
```

### static (static site)

| | |
|---|---|
| **default_version** | `126` (nginx 1.26) |
| **service_types** | `image` only |
| **Notable** | Builds the frontend (npm/yarn/pnpm, if `package.json` exists) and packages it into an nginx image via s2i; no `test`/`publish` steps. A single version is pinned (nginx 1.26) — the schema marks `versions: false`, so no version picker is offered |

```yaml
# GitLab
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/static@1.0.0
    inputs: { service_type: image }
```

### Other components (not tied to a runtime)

Three additional GitLab components aren't tied to any runtime — for cases where the app
is already built outside this pipeline, or only analysis/Helm is needed:

| Component | Purpose |
|---|---|
| `image` | An image from an existing Containerfile/Dockerfile, CEKit, or a base image — no application build (`image:build` → `image:scan` → `image:publish`) |
| `helm` | Helm chart: `helm lint` + `kubeconform`, then publish to the chart repository |
| `analyze` | Analysis without a build: `deps:scan`, `sonar`, `svace`, `appscreener` — on existing sources |

```yaml
# GitLab — publish an already-built image
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/image@1.0.0
    inputs: { workdir: . }
```

---

## 5. Every CI/CD System

All three share one contract — `ci <step>`. The only difference is how each system
describes the job graph and logic (branches/retry/manual).

### GitLab CI/CD

Components (`templates/*.yml`), included via `include: component:`. GitLab's limit is
~100 components per project; so granular components only cover
`build/test/lint/publish/image:*`, while analysis/scan/CD steps stay in the bundle as
input toggles (see §3, Level 3).

**Level 1/2** — see the examples in §3 and §4 (one `include:` per runtime bundle).

**Level 3 (granular)**:

```yaml
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/maven-build@$CI_COMMIT_SHA
    inputs: { runtime_version: "21" }
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/maven-test@$CI_COMMIT_SHA
    inputs: { runtime_version: "21" }

test:
  needs: [build]
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
      changes: [src/**/*, pom.xml]
```

Details and the full inputs table — [adapters/gitlab/README.md](adapters/gitlab/README.md).

### GitHub Actions

A composite action (`adapters/github/action.yml`) for a single step, or a reusable
workflow (`pipeline.yml`) for the whole graph.

**Level 1/2 (reusable workflow)**:

```yaml
name: CI
on:
  push:
    branches: [main, develop]
  pull_request:

jobs:
  hci:
    uses: org/templates/.github/workflows/hci.yml@v1.0.0
    with:
      runtime: maven
      runtime-version: "21"
      service-type: image
      build-image: registry.example/ci-openjdk-21:…
      tools-image: registry.example/ci-tools:…
      test: true
      sonar: false
      image-publish: true
    secrets: inherit
```

For other publish conditions — fork `pipeline.yml` into your repo and edit `if:` like any
GitHub Actions YAML (it's not a separate DSL — plain GitHub Actions).

**Level 3 (granular, via `step:` on the composite action)**:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: org/templates/adapters/github@${{ github.sha }}
        with: { runtime: maven, runtime-version: "21", step: build }

  test:
    runs-on: ubuntu-latest
    needs: build
    steps:
      - uses: actions/checkout@v4
      - uses: org/templates/adapters/github@${{ github.sha }}
        with: { runtime: maven, runtime-version: "21", step: test }
```

Details — [adapters/github/README.md](adapters/github/README.md).

### Jenkins

Shared library: `hci('build')` for one step, `hciPipeline(...)` for the whole graph. All
branching logic is native Declarative/Scripted Groovy (`when`, `retry()`, `input`), no
separate DSL.

**Level 1/2 (hciPipeline)**:

```groovy
@Library('hyperion-ci') _

hciPipeline(
  runtime: 'maven',
  runtimeVersion: '21',
  serviceType: 'image',
  buildImage: 'registry.example/ci-openjdk-21:…',
  toolsImage: 'registry.example/ci-tools:…',
)
```

**Level 3 (granular, calling `hci()` directly)**:

```groovy
@Library('hyperion-ci') _

pipeline {
  agent { docker { image 'registry.example/ci-openjdk-21:…' } }
  stages {
    stage('build') {
      steps { script { hci(step: 'build') } }
    }
    stage('test') {
      when { branch 'main' }
      steps { script { hci(step: 'test', strict: false) } }
    }
  }
}
```

Code **78** → `unstable` job (neither red nor green). Details —
[adapters/jenkins/README.md](adapters/jenkins/README.md).

---

## 6. CD: `cd:bump` and `cd:notify` — on every CI system

Two independent optional steps (off by default) for GitOps deployment:

- **`cd:bump`** — clones the GitOps repository, edits a single YAML path (image tag/digest)
  via `yq`, commits, and pushes. On conflict (`non-fast-forward`/`fetch first`) it
  reloads the branch and reapplies the edit on its own; on a network error it simply
  retries the push. Hard failure (not soft-exit 78) — a deploy error must never be
  silently swallowed.
- **`cd:notify`** — sends an authenticated HTTP webhook to a GitOps controller (ArgoCD,
  Flux, any endpoint). If both steps are enabled, `cd:notify` automatically waits for
  `cd:bump` (an `optional: true` dependency — enabling only `cd:notify` also works).

Both run only on a tag by default (like `image:publish`).

### GitLab

```yaml
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/maven@1.0.0
    inputs:
      runtime_version: "21"
      service_type: image
      image_publish: true
      cd_bump: true
      cd_notify: true

cd:bump:
  variables:
    HCI_CD_GIT_URL: "https://gitlab.example.com/gitops/manifests.git"
    HCI_CD_GIT_BRANCH: "main"
    HCI_CD_GIT_TOKEN: "$CI_JOB_TOKEN"
    HCI_CD_YAML_FILE: "deploy/service.yaml"
    HCI_CD_YAML_PATH: ".spec.template.spec.containers[0].image"

cd:notify:
  variables:
    HCI_CD_NOTIFY_URL: "https://argocd.example.com/api/webhooks"
    HCI_CD_NOTIFY_TOKEN: "$ARGOCD_WEBHOOK_TOKEN"
    HCI_CD_NOTIFY_BODY: '{"action":"sync"}'
```

### GitHub Actions

`pipeline.yml` (reusable workflow) **does not have** `cd-bump`/`cd-notify` inputs —
unlike the GitLab bundles, it doesn't wrap the full set of optional steps (same is true
for `svace`/`appscreener`/`kcs`/`helm:*`). The only way to call `cd:bump`/`cd:notify` on
GitHub is to add a job that calls the composite action directly with the right `step:`,
after the job from `pipeline.yml`:

```yaml
jobs:
  hci:
    uses: org/templates/.github/workflows/hci.yml@v1.0.0
    with:
      runtime: maven
      runtime-version: "21"
      service-type: image
      image-publish: true
    secrets: inherit

  cd-bump:
    runs-on: ubuntu-latest
    needs: hci
    if: startsWith(github.ref, 'refs/tags/')
    steps:
      - uses: actions/checkout@v4
      - uses: org/templates/adapters/github@${{ github.sha }}
        with: { step: cd:bump }
        env:
          HCI_CD_GIT_URL: https://github.com/org/gitops-manifests.git
          HCI_CD_GIT_USER: x-access-token
          HCI_CD_GIT_TOKEN: ${{ secrets.GITOPS_PUSH_TOKEN }}
          HCI_CD_YAML_FILE: deploy/service.yaml
          HCI_CD_YAML_PATH: .spec.template.spec.containers[0].image

  cd-notify:
    runs-on: ubuntu-latest
    needs: cd-bump
    if: startsWith(github.ref, 'refs/tags/')
    steps:
      - uses: org/templates/adapters/github@${{ github.sha }}
        with: { step: cd:notify }
        env:
          HCI_CD_NOTIFY_URL: https://argocd.example.com/api/webhooks
          HCI_CD_NOTIFY_TOKEN: ${{ secrets.ARGOCD_WEBHOOK_TOKEN }}
          HCI_CD_NOTIFY_BODY: '{"action":"sync"}'
```

### Jenkins

`hciPipeline(...)` also has no `cd:bump`/`cd:notify` stages (same for
`svace`/`appscreener`/`kcs`/`helm:*`) — call `hci(step: 'cd:bump')` directly in your own
Jenkinsfile, after the `image:publish` stage:

```groovy
@Library('hyperion-ci') _

pipeline {
  agent { docker { image 'registry.example/ci-openjdk-21:…' } }
  environment {
    HCI_CD_GIT_URL          = 'https://gitlab.example.com/gitops/manifests.git'
    HCI_CD_GIT_BRANCH       = 'main'
    HCI_CD_GIT_TOKEN        = credentials('gitops-push-token')
    HCI_CD_YAML_FILE        = 'deploy/service.yaml'
    HCI_CD_YAML_PATH        = '.spec.template.spec.containers[0].image'
    HCI_CD_NOTIFY_URL       = 'https://argocd.example.com/api/webhooks'
    HCI_CD_NOTIFY_TOKEN     = credentials('argocd-webhook-token')
  }
  stages {
    stage('build')   { steps { script { hci(step: 'build') } } }
    stage('image')   {
      when { tag '*' }
      steps { script { hci(step: 'image:build'); hci(step: 'image:publish') } }
    }
    stage('deploy') {
      when { tag '*' }
      steps { script { hci(step: 'cd:bump'); hci(step: 'cd:notify') } }
    }
  }
}
```

### General notes (all three systems)

- **HTTPS token**: set the platform username in `HCI_CD_GIT_USER` —
  GitLab: `oauth2` (default), GitHub App: `x-access-token`, Bitbucket Cloud: `x-token-auth`.
- **SSH key**: `HCI_CD_GIT_SSH_KEY`/`HCI_CD_GIT_SSH_KNOWN_HOSTS` accept a file path or raw
  content. In GitLab, declare them as a **File**-type variable, not Masked (multi-line
  values can't be masked).
- **Multi-document YAML** (several `---`-separated manifests in one file — common for
  Argo/Flux): `HCI_CD_YAML_PATH` must be guarded with `select()`:
  `(select(.kind=="Deployment").spec.template.spec.containers[0].image)`.
- **Secret in the webhook URL**: don't put `?token=...` in `HCI_CD_NOTIFY_URL` (this
  variable isn't masked — GitLab masking rejects values containing `/`). Use
  `HCI_CD_NOTIFY_TOKEN` instead, it's sent as `Authorization: Bearer <token>`.
- **kustomize is not supported** — only direct YAML-path edits via `yq`. The typical case
  (`image:` in a Deployment/values.yaml) is fully covered; `kustomize` would need its own
  binary in the tools image — out of scope for this version.

Full CD documentation (edge cases, troubleshooting) —
[docs/pipeline.md §CD](docs/pipeline.md#cd-cdbump-and-cdnotify).

---

## 7. Configuration Reference

### All steps (`ci help`)

| Step | Purpose | Soft-exit (78) at `strict: false` |
|-----|-----------|:---:|
| `build` | build (+ package a library when `service_type: library`) | — |
| `test` | unit tests with coverage | ✅ |
| `lint` | linters | ✅ |
| `publish` | publish a library to a package registry | — |
| `image:build` | build the image (`base`/`dockerfile`/`s2i`/`cekit`) | — |
| `image:scan` | image analysis (Trivy) + SBOM | ✅ |
| `image:publish` | publish, sign, attest the image | — |
| `sbom` | image SBOM on its own | — |
| `deps:scan` | dependency analysis (Trivy fs) | ✅ |
| `sonar` | SonarQube | ✅ |
| `svace` | Svace | ✅ |
| `appscreener` | Solar appScreener | ✅ |
| `kcs` | Kaspersky Container Security | ✅ |
| `helm:lint` | Helm chart check | — |
| `helm:publish` | publish the Helm chart | — |
| `cd:bump` | bump the image ref in the GitOps manifest (git commit+push) | — (hard fail) |
| `cd:notify` | webhook trigger for the GitOps controller | — (hard fail) |

Service commands: `config` (final configuration with secrets masked), `detect` (detect
the runtime/tools), `images` (build/runtime images for the current runtime),
`manifest:validate`, `run -- <command>` (run an arbitrary command inside the runtime
environment), `version`.

### Configuration cascade

1. CLI: `ci build --runtime-version=21`
2. Environment variables: `HCI_RUNTIME_VERSION=21`
3. The project's `.ci.yaml`
4. `core/runtimes/<rt>/defaults.env`
5. `core/defaults.env`

### `.ci.yaml` — example

```yaml
runtime: maven
service_type: image
runtime_version: "21"
profile: none          # quarkus for Maven
strict: true
image:
  build_mode: auto      # auto | base | dockerfile | s2i | cekit
  platforms: [linux/amd64]
  context: target/*.jar
  labels: { team: payments }
build:
  cmd: mvn -q package   # full step replacement
env:
  MAVEN_OPTS: "-Xmx1g"
```

Disable a step: `HCI_TEST_ENABLED=false` or the `test: false` input.
Strictness: `HCI_STRICT` (globally) and `HCI_TEST_STRICT` (per step).

### Custom step command (`HCI_<STEP>_CMD`) — a full replacement for non-standard builds

Every step has an `HCI_<STEP>_CMD` variable (step name upper-cased, `:`/`-` → `_`:
`build` → `HCI_BUILD_CMD`, `image:build` → `HCI_IMAGE_BUILD_CMD`, `deps:scan` →
`HCI_DEPS_SCAN_CMD`). If it's set, the dispatcher (`core/lib/dispatch.sh`) does not call
the runtime's built-in implementation — instead it runs `eval` on the variable's value:
an inline command, an `&&` chain, or a path to your own script.

```yaml
# .ci.yaml — build.cmd is automatically turned into HCI_BUILD_CMD
build:
  cmd: ./ci/my-weird-build.sh --target=embedded
```

What's preserved regardless:

- **Runtime setup still runs** — for steps in `HCI_SETUP_STEPS` (`build`, `test`, `lint`,
  `publish`, `sonar`, `svace`) the environment (registries, caches, toolchain from the
  image) is configured BEFORE your command — your script runs against an environment
  that's already set up, not one it has to build from scratch.
- **The exit code is interpreted the same way** as the built-in logic: soft steps
  (`test`, `lint`, `image:scan`, `deps:scan`, `sonar`, `svace`, `appscreener`, `kcs`) at
  `strict: false` produce soft-exit 78 instead of failing the pipeline, even with a
  custom command.

Don't confuse this with `HCI_IMAGE_CMD` (no `_BUILD_`) — that's a narrow parameter only
for s2i mode inside the built-in `image:build` (it overrides `/usr/libexec/s2i/run`), not
a general step-override mechanism.

### Hooks — add, don't replace

- Files `.ci/hooks/<step>.pre.sh` and `.post.sh` (`:` in the step name becomes `-`, so for
  `image:build` it's `.ci/hooks/image-build.pre.sh`).
- Inline: `HCI_BUILD_PRE`, `HCI_BUILD_POST`, and likewise for other steps.

Hooks run **around** the step (before/after), without disabling the built-in
implementation or `HCI_<STEP>_CMD` — for light extra processing (warm a cache, send a
metric). For a full replacement of the step's logic, use `HCI_<STEP>_CMD` above.

### Registries

`HCI_REGISTRY_<TYPE>_{HOST,USER,PASSWORD,PULL_REPO,REPO}` for types `OCI`, `OCI_PUSH`,
`MAVEN`, `NPM`, `NUGET`, `PYPI`, `CARGO`, `GO`, `HELM`, `COMPOSER`. Empty values fall back
to the shared `HCI_REGISTRY_*` (which default from `NEXUS_*`).

### CD variables (`cd:bump` / `cd:notify`)

| Variable | Purpose | Default |
|---|---|---|
| `HCI_CD_GIT_URL` | GitOps repository URL (no userinfo!) | — |
| `HCI_CD_GIT_BRANCH` | target branch | the repository's HEAD |
| `HCI_CD_GIT_TOKEN` | HTTPS token (via `GIT_ASKPASS`, never in the URL) | — |
| `HCI_CD_GIT_USER` | username for the HTTPS token | `oauth2` |
| `HCI_CD_GIT_SSH_KEY` / `HCI_CD_GIT_SSH_KNOWN_HOSTS` | path or content of the key/known_hosts | — |
| `HCI_CD_GIT_SSH_INSECURE` | skip host-key checking (not for prod) | `false` |
| `HCI_CD_GIT_USER_NAME` / `HCI_CD_GIT_USER_EMAIL` | commit author | `hyperion-ci` / `ci@localhost` |
| `HCI_CD_IMAGE` | explicit image ref instead of reading the artifact manifest | — |
| `HCI_CD_YAML_FILE` | path to the manifest file in the GitOps repo | — |
| `HCI_CD_YAML_PATH` | yq path to the image field (use `select()` for multi-doc) | — |
| `HCI_CD_NOTIFY_URL` | webhook URL (not masked — don't put a secret in the query!) | — |
| `HCI_CD_NOTIFY_METHOD` | HTTP method | `POST` |
| `HCI_CD_NOTIFY_TOKEN` | bearer token for the webhook | — |
| `HCI_CD_NOTIFY_BODY` | request body | — |
| `HCI_CD_NOTIFY_TIMEOUT` | request timeout, seconds | `30` |

### Air-gapped environments

The pipeline is designed to work without direct public-internet access — almost
everything already routes through internal registries/servers by default or by config:

| What | How it already works |
|---|---|
| Build/runtime/sonar/svace images | Always through `${HCI_REGISTRY_OCI_HOST}/${HCI_IMAGES_FOLDER}/...` (meta.yaml) — they expect an internal registry, not Docker Hub/GHCR |
| Package registries (maven/npm/pip/…) | `HCI_REGISTRY_<TYPE>_*` → an internal Nexus proxy, see [§Registries](#registries) |
| SonarQube | `HCI_SONAR_HOST_URL` (from `SONAR_HOST`) — always an internal server, the scanner never reaches the internet |
| Trivy | **Server mode** by default: `HCI_TRIVY_SERVER` = `http://trivy:8080` — the vulnerability DB is updated by the server, not the job |

**Trivy standalone** (if `HCI_TRIVY_SERVER` is empty — no central Trivy server): without
a server, Trivy pulls its DB from `ghcr.io/aquasecurity` on every scan. To use an internal
DB mirror instead:

```bash
HCI_TRIVY_SERVER=""                                            # disable server mode
HCI_TRIVY_DB_REPOSITORY="internal.example/mirror/trivy-db"
HCI_TRIVY_JAVA_DB_REPOSITORY="internal.example/mirror/trivy-java-db"
```

Both variables are empty by default — Trivy's behavior (defaulting to `ghcr.io`) doesn't
change until you set them explicitly.

**`jq`/`yq` in the tools image** — the only place hardcoded to the public internet, but
this is **not** the project pipeline's own execution — it's a one-off wrapper-image build
(`tools/fetch-binaries.sh`, run when building the `/opt/ci` image, not on every service
commit). Override it via env at image-build time:

```bash
JQ_URL="https://nexus.internal/raw/jq-1.7.1-linux-amd64" \
YQ_URL="https://nexus.internal/raw/yq_v4.44.3_linux_amd64" \
  bash tools/fetch-binaries.sh
```

Without an override, the default is `github.com/jqlang/jq` and `github.com/mikefarah/yq`
(the same files, just without a mirror).

### Artifact manifest

`hci-artifacts/artifacts.json`, schema `core/schema/artifacts.v2.json`. Written only
through `manifest::add`. Check with `ci manifest:validate`.

### Local run (no CI)

```bash
export PATH="$PWD/core/bin:$PATH"
ci detect
ci build --runtime=maven --workdir=tests/fixtures/maven-service
ci help
```

### Generating GitLab components

```bash
python3 tools/generate.py          # regenerate templates/*.yml, wrappers, schema.yaml
python3 tools/generate.py --check  # in CI: fails if artifacts are stale
```

`templates/*.yml` is never hand-edited — only `core/runtimes/*/meta.yaml` +
`tools/generate.py`.
