[English](pipeline.md) | [Русский](pipeline.ru.md)

# Pipeline Logic Construction

Logic (branches, `when`, retry, OR/AND, manual) lives **in the project's YAML** — not in
the template generator. For Jenkins — in the `Jenkinsfile` / shared-library call (Groovy).

Decision context: [DECISIONS.md](DECISIONS.md).

A component only provides a thin DAG: jobs → `ci <step>`. Default `rules` are minimal
(step on/off, `service_type`, publish-on-tag). Everything else is an override.

## Usage Levels

A pipeline can be built in three ways, in increasing order of flexibility:

- **Level 1** — quick start with a ready-made pipeline. Include a component
  (`include: component: …/maven@tag`), pick a runtime and a service type (image or
  library). The default graph is documented below. Already covered in
  [README.md](../README.md).

- **Level 2** — customizing the ready-made pipeline. Turn individual steps on/off
  (`test: false`, `sonar: true`), pass parameters (runtime version, registries via
  `.ci.yaml` / `HCI_*`), override logic in the project's YAML (`rules`, `needs`, `retry`,
  `when`). This is what the rest of this document covers:
  [GitLab](#gitlab-gitlab-ciyml-as-a-construction-kit), [GitHub](#github-actions),
  [Jenkins](#jenkins).

- **Level 3** — a custom graph from individual components. For non-typical step
  combinations: e.g. several tests with different parameters, lint in parallel, publish
  without building an image. Include only the steps you need
  (`maven-build`, `maven-test`, `image:scan`), wire dependencies by hand. Details:
  [Level 3](#level-3-a-custom-graph-from-individual-components) below.

## GitLab: `.gitlab-ci.yml` as a construction kit

```yaml
include:
  - component: $CI_SERVER_FQDN/<group>/templates/maven@1.0.0
    inputs:
      runtime_version: "21"
      service_type: image
      test: true
      sonar: false
      image_publish: true

# --- logic below: plain GitLab CI YAML ---

workflow:
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH =~ /^(main|develop)$/
    - if: $CI_COMMIT_TAG

build:
  retry:
    max: 2
    when: [runner_system_failure, stuck_or_timeout_failure]

test:
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
      changes:
        - src/**/*
        - pom.xml

image:publish:
  rules:
    - if: $CI_COMMIT_TAG
    - if: $CI_COMMIT_BRANCH == "main"
      when: manual
      allow_failure: true

# disable a job entirely
sonar:
  rules:
    - when: never
```

Job names = step names (`build`, `test`, `image:publish`, …).
With `job_prefix: "svc:"` → `svc:build`, `svc:test`, …

### What can be overridden

Any field of a GitLab job: `rules`, `retry`, `needs`, `when`, `only`/`except` (legacy),
`interruptible`, `tags`, `image`, `before_script`, `after_script`, `artifacts`, …

Component inputs are convenient step toggles and runtime parameters, not a replacement
for `rules`.

### Step behavior (not the graph)

Commands, hooks, registries — `.ci.yaml` / `HCI_*` (the `ci <step>` core). This is
separate from pipeline logic.

## GitHub Actions

A reusable workflow — a thin graph. Logic lives in the calling workflow:

```yaml
on:
  push:
    branches: [main, develop]
  pull_request:
  workflow_dispatch:

jobs:
  hci:
    uses: org/templates/.github/workflows/hci.yml@v1
    with:
      runtime: maven
      runtime-version: "21"
      build-image: …
      tools-image: …
      image-publish: true
    # conditions — at the caller's jobs.<id>.if level, or fork the workflow
```

Copy `pipeline.yml` into your repo and edit `if:` / `on:` like any Actions YAML.

## Jenkins

The construction kit is Groovy (`Jenkinsfile` or a wrapper over `hciPipeline`):

```groovy
hciPipeline(
  runtime: 'maven',
  runtimeVersion: '21',
  buildImage: '…',
  toolsImage: '…',
)

// or your own pipeline { stages { when { branch 'main' }; steps { hci('build') } } }
```

`when { }`, `retry()`, `input` — plain Declarative/Scripted Jenkins, no separate DSL.

## Level 3: a custom graph from individual components

### Which steps are available granularly?

Individual components per runtime: `build`, `test`, `lint`, `publish`, and the image —
`image:build`, `image:scan`, `image:publish`. These steps are often combined in
non-typical graphs (e.g. a test without publish, or several `test` runs with different
parameters).

Analysis and scans — `deps:scan`, `sonar`, `svace`, `appscreener`, `kcs` — stay bundle-only
(`analyze.yml`, `image.yml`). In practice they're always switched on/off as a batch via
level-2 input variables, never assembled piece by piece. This isn't a loss of
functionality (level 2 already gives a toggle for each one) — it's saving a scarce
resource, the component count.

**Dependency chain:**
- `lint`, `deps:scan`, `appscreener`, `svace` are independent of `build` (they work on
  sources)
- `test`, `sonar`, `publish`, `image:build` require `build`
- `image:scan`, `kcs`, `image:publish` transitively require `image:build`

### Recipes per CI system

#### GitLab: granular components

```yaml
include:
  - component: $CI_SERVER_FQDN/<group>/templates/maven-build@$CI_COMMIT_SHA
    inputs:
      runtime_version: "21"
  - component: $CI_SERVER_FQDN/<group>/templates/maven-test@$CI_COMMIT_SHA
    inputs:
      runtime_version: "21"

# Set dependencies and conditions by hand, in one block — not as separate `test:`
# keys, or the second key would silently clobber the first in YAML
test:
  needs:
    - build
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
      changes:
        - src/**/*
```

Note: every granular component with the same `job_prefix` must use that same
`job_prefix` (just like with bundles) — otherwise `needs:` won't find the right job name.

#### GitHub Actions: granular components

The composite action `action.yml` supports calling individual steps via the `step` input:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: org/templates/adapters/github@${{ github.sha }}
        with:
          runtime: maven
          runtime-version: "21"
          step: build

  test:
    runs-on: ubuntu-latest
    needs: build
    steps:
      - uses: actions/checkout@v4
      - uses: org/templates/adapters/github@${{ github.sha }}
        with:
          runtime: maven
          runtime-version: "21"
          step: test
```

#### Jenkins: granular components

Call steps directly from your own `Jenkinsfile`, bypassing `hciPipeline()`:

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

### Granular file dependencies

Components that require logical predecessors:

| Component | Requires | What happens without it |
|-----------|---------|-------------------------------|
| `*-image-scan.yml` | `*-image-build.yml` with the same `job_prefix` | `log::die` at step start, on the missing OCI image directory |
| `*-image-publish.yml` | `*-image-build.yml` with the same `job_prefix` | `log::die` at step start, on the missing OCI image directory |

The error is immediate (it fires in the step's `script:`), the artifact name is explicit,
the diagnostic is self-explanatory.

### Granular file defaults

Granular components use a narrower default than bundles:
- No `HCI_JOB_ENABLED` — choosing the component file itself is the enable signal
- No `service_type` gate — they work for every service type
- Publish jobs (`*-publish.yml`, `*-image-publish.yml`) still only run on a tag (the
  `tag_only` rule)

## CD: `cd:bump` and `cd:notify`

### `cd:bump`

Updates GitOps manifests: clones the repository, edits a single YAML path (image tag or
digest) via `yq`, commits and pushes to a branch. On a merge conflict it automatically
reloads the remote branch and recomputes the edit. An optional step (off by default),
hard-fails on error. Runs on a tag by default (the `image_only, tag_only` rule, same as
`image:publish`).

### `cd:notify`

Sends an authenticated HTTP webhook to notify a GitOps controller of the update. Works
with any HTTP receiver: ArgoCD, Flux notification-controller, custom ones. An optional
step (off by default), hard-fail, runs on a tag by default. If both steps are enabled,
`cd:notify` automatically waits for `cd:bump` (the dependency is wired by the generator
automatically with `optional: true`, so enabling only `cd:notify` without `cd:bump` works
too, if desired).

### Using both steps together

```yaml
include:
  - component: $CI_SERVER_FQDN/<group>/templates/maven@1.0.0
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
    HCI_CD_NOTIFY_METHOD: "POST"
    HCI_CD_NOTIFY_BODY: '{"action":"sync"}'
    HCI_CD_NOTIFY_TOKEN: "$ARGOCD_WEBHOOK_TOKEN"
```

### Credentials and access

#### `HCI_CD_GIT_USER` by platform

When using HTTPS with a token, set the platform username in `HCI_CD_GIT_USER`:

| Platform | `HCI_CD_GIT_USER` |
|---|---|
| GitLab | `oauth2` (default) |
| GitHub App | `x-access-token` |
| Bitbucket Cloud | `x-token-auth` or a real username |

#### SSH keys and known_hosts

`HCI_CD_GIT_SSH_KEY` and `HCI_CD_GIT_SSH_KNOWN_HOSTS` accept either a file path or raw
content.

**Recommendation**: declare them as GitLab **File**-type CI/CD variables (not Masked).
Reason — GitLab masking doesn't support multi-line values; a multi-line private SSH key
and a `known_hosts` block simply can't be masked when saved as a Masked variable. A File
variable instead gives the step a path to the file inside the container, avoiding the
issue:

```yaml
# In GitLab CI/CD Settings → Variables:
# HCI_CD_GIT_SSH_KEY (type: File) = upload the private key
# HCI_CD_GIT_SSH_KNOWN_HOSTS (type: File) = upload known_hosts
```

### Multi-document YAML manifests

If the target manifest file contains several documents separated by `---` (common in
Argo CD / Flux repos — a Service + Deployment in one file), `HCI_CD_YAML_PATH` must be
guarded with a `select()` expression. Otherwise the path could accidentally match the
wrong document in the same file, failing the gate.

Correct example:

```bash
HCI_CD_YAML_PATH='(select(.kind=="Deployment").spec.template.spec.containers[0].image)'
```

The expression returns the image path **only** from the block with `kind: Deployment`,
ignoring neighboring Service documents.

### Webhooks and tokens

`HCI_CD_NOTIFY_URL` is **not masked** automatically. Reason: GitLab masking rejects
values containing `/`, and a URL always has one. This same variable isn't caught by the
project's own regex redactor (`log::redact`) either.

If the webhook needs a secret (a common `?token=...` query-string pattern), **don't put
the secret in the URL itself**. Use `HCI_CD_NOTIFY_TOKEN` instead — it's sent as
`Authorization: Bearer <token>` and is protected from log leaks:

```bash
# Bad:
HCI_CD_NOTIFY_URL='https://webhook.example.com/hook?token=secret123'

# Good:
HCI_CD_NOTIFY_URL='https://webhook.example.com/hook'
HCI_CD_NOTIFY_TOKEN='secret123'  # sent in the Authorization header
```

### Edge cases

**If `cd_notify: true` is enabled but `cd_bump: false` and `image_publish: false`, with no
explicit `HCI_CD_IMAGE`:** the pipeline won't assemble (a generator-level error — `needs`
on non-existent steps). This is an unusual configuration; if you hit it, double-check your
pipeline's logic by hand. The fix is to either enable `image_publish`, or set
`HCI_CD_IMAGE` explicitly from some other source.

### Non-Goal: `kustomize`

Editing manifests via `kustomize` is **not supported** in this version. The `kustomize`
binary is absent from the project's tools image (confirmed in `tools/fetch-binaries.sh` —
only `yq` is there). Adding `kustomize` support would require extending
`tools/fetch-binaries.sh` and rebuilding the tools image — a separate piece of work, out
of scope for this change. Direct YAML-path editing via `yq` fully covers the typical case
(the `image:` field in a Deployment / values.yaml).

## Layers (brief)

| Layer | Where | Responsibility |
|------|-----|-----------------|
| Default graph | `templates/*.yml` (generated) | jobs + `ci <step>`, minimal rules |
| Pipeline logic | **project YAML/Groovy** | branches, retry, manual, OR/AND, changes |
| Step behavior | `.ci.yaml` / env / hooks | build/test/publish commands |
