[English](README.md) | [Русский](README.ru.md)

# GitHub Actions Adapter

A thin layer: a job calls `ci <step>`. Logic (`on:`, `if:`) lives in **your** workflow.
See [docs/pipeline.md](../../docs/pipeline.md).

## Contents

| File | Purpose |
|------|------------|
| `action.yml` | A composite action for a single step |
| `pipeline.yml` | A reusable workflow (thin DAG) |
| `../common/run-step.sh` | Soft-exit **78** → warning |

```bash
bash tools/link-github-adapter.sh
```

## Reusable Workflow

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
    secrets: inherit
```

Need other publish conditions — copy `pipeline.yml` and edit `if:` like plain Actions
YAML.

## Granular Components

For a fully custom graph built from individual components, see
[Level 3](../../docs/pipeline.md#level-3-a-custom-graph-from-individual-components):

```yaml
jobs:
  build:
    uses: org/templates/adapters/github@${{ github.sha }}
    with:
      runtime: maven
      runtime-version: "21"
      step: build
```
