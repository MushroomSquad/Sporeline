[English](README.md) | Русский

# GitHub Actions — адаптер

Тонкий слой: job вызывает `ci <step>`. Логика (`on:`, `if:`) — в **вашем** workflow.
См. [docs/pipeline.md](../../docs/pipeline.ru.md).

## Состав

| Файл | Назначение |
|------|------------|
| `action.yml` | Composite action на один шаг |
| `pipeline.yml` | Reusable workflow (тонкий DAG) |
| `../common/run-step.sh` | Soft-exit **78** → warning |

```bash
bash tools/link-github-adapter.sh
```

## Reusable workflow

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

Нужны другие условия publish — скопируйте `pipeline.yml` и правьте `if:` как обычный Actions YAML.

## Гранулярные компоненты

Для полностью кастомного графа из отдельных компонентов см. [Уровень 3](../../docs/pipeline.ru.md#уровень-3-свой-граф-из-отдельных-компонентов):

```yaml
jobs:
  build:
    uses: org/templates/adapters/github@${{ github.sha }}
    with:
      runtime: maven
      runtime-version: "21"
      step: build
```
