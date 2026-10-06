# Гиперион CI

CI-независимое ядро (`ci <шаг>` на bash) плюс тонкие адаптеры для GitLab CI/CD Components,
GitHub Actions и Jenkins shared library. Один и тот же `ci`-бинарник, запечённый в образ
сборки, вызывается одинаково из всех трёх систем. YAML/Groovy описывают только граф джобов.

Более узкие детали — в [docs/pipeline.md](docs/pipeline.md) (конструктор логики пайплайна,
полные edge cases CD) и [docs/DECISIONS.md](docs/DECISIONS.md) (история решений: что
опробовали и отклонили, и почему).

## Содержание

1. [Что это и почему так устроено](#1-что-это-и-почему-так-устроено)
2. [Как это работает (архитектура)](#2-как-это-работает-архитектура)
3. [Три уровня использования — с примерами](#3-три-уровня-использования--с-примерами)
4. [Каждый рантайм](#4-каждый-рантайм)
5. [Каждая CI/CD-система](#5-каждая-cicd-система)
6. [CD: bump и notify — на каждой CI-системе](#6-cd-bump-и-notify--на-каждой-ci-системе)
7. [Справочник конфигурации](#7-справочник-конфигурации)

---

## 1. Что это и почему так устроено

**Что.** CI-независимое ядро (`ci <шаг>` на bash) плюс тонкие адаптеры для
GitLab CI/CD Components, GitHub Actions и Jenkins shared library. Один и тот же бинарник
`ci`, запечённый в образ сборки, вызывается одинаково из всех трёх систем.

**Почему не "один большой пайплайн на YAML".** Три повторяющиеся проблемы в типичных
CI-шаблонах: (1) логика сборки размазана по `script:` блокам и копируется между рантаймами
с мелкими расхождениями; (2) "конструкторы" пайплайна в generate-скриптах превращаются в
DSL поверх DSL — пресеты вместо реальной гибкости; (3) смена одной CI-системы на другую
означает переписывание всей логики с нуля. Решение: вынести *поведение* шага (как собирать,
тестировать, публиковать) в bash-ядро, а *логику графа* (когда шаг нужен — ветки, retry,
manual, условия) оставить в нативном языке каждой CI-системы — GitLab YAML, GitHub Actions
YAML, Jenkins Groovy. Подробное обоснование каждого решения и то, что было опробовано и
отклонено (полноценный конструктор логики в генераторе, платформенный UI, свободный DSL
в inputs) — в [docs/DECISIONS.md](docs/DECISIONS.md).

**Как (одним абзацем).** `ci <step>` — диспетчер (`core/bin/ci` → `core/lib/dispatch.sh`),
который находит `step::<name>` в `core/steps/*.sh` или `core/runtimes/<rt>/lib.sh`,
собирает конфигурацию по каскаду приоритетов и выполняет шаг. Адаптеры (`templates/*.yml`
для GitLab, `adapters/github/*`, `adapters/jenkins/*`) — это только граф джобов, вызывающий
`ci <step>` с нужными переменными. `tools/generate.py` — dev-time генератор GitLab-компонентов
из `core/runtimes/*/meta.yaml`, чтобы не копипастить почти одинаковые файлы на 10 рантаймов;
он не участвует в выполнении пайплайна и не содержит логики ветвления.

---

## 2. Как это работает (архитектура)

```
core/
  bin/ci                  # entrypoint: ci <step> [--key=value ...]
  lib/dispatch.sh          # находит step::<name>, запускает setup рантайма
  lib/config.sh            # каскад конфигурации, маскирование секретов в логах
  lib/*.sh                 # retry, manifest, tls, log, ci-env (нормализация платформы)
  steps/*.sh                # общие шаги: image-build, image-scan, sonar, cd-bump, cd-notify, …
  runtimes/<rt>/
    meta.yaml               # версии, service_types, steps, cache, reports — источник истины
    lib.sh                   # step::build / step::test / … для этого рантайма
    defaults.env             # дефолты, специфичные для рантайма
  defaults.env              # дефолты ядра

templates/*.yml              # GitLab CI/CD Components (генерируются из meta.yaml)
adapters/
  gitlab/README.md
  github/{action.yml,pipeline.yml}
  jenkins/vars/{hci.groovy,hciPipeline.groovy}
  common/run-step.sh         # общая soft-exit обёртка (код 78 → warning/unstable)

tools/generate.py            # генератор templates/*.yml, wrappers, schema.yaml, e2e-матрицы
```

**Каскад конфигурации** (выше — важнее): CLI `--key=value` → переменные окружения →
`.ci.yaml` проекта → `core/runtimes/<rt>/defaults.env` → `core/defaults.env`.
Все ключи ядра — в namespace `HCI_*`, чтобы не пересекаться с `CI_*` (GitLab),
`GITHUB_*`, `JENKINS_*`.

**Коды возврата:** `0` — успех; **78** — мягкий отказ (тест/линтер/скан с `strict=false`):
GitLab видит `allow_failure: exit_codes: [78]`, Jenkins — `unstable`, GitHub — warning;
**86** — явный пропуск шага (например, нет исходников для шага).

**Манифест артефактов** — `hci-artifacts/artifacts.json` (схема `core/schema/artifacts.v2.json`),
пишется только через `manifest::add`, читается шагами вроде `cd:bump` (image digest) и
проверяется `ci manifest:validate`.

**Версия ядра**: тег обёрточного образа сборки совпадает с `core/VERSION` (суффикс
`-ci1.0.0`) — при апдейте ядра обновляются все образы разом, без ручной синхронизации
тегов по рантаймам.

---

## 3. Три уровня использования — с примерами

### Уровень 1 — быстрый старт готовым пайплайном

Подключить один компонент, выбрать рантайм и `service_type`. Весь граф (build → test →
image:build → image:scan → image:publish, lint/sonar/deps:scan по вкусу) уже внутри.

```yaml
# .gitlab-ci.yml
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/maven@$CI_COMMIT_SHA
    inputs:
      runtime_version: "21"
      service_type: image
```

### Уровень 2 — кастомизация готового пайплайна

Включать/выключать шаги через inputs, передавать параметры поведения через `.ci.yaml` /
`HCI_*`, переопределять логику графа (`rules`, `needs`, `retry`, `when`) в YAML проекта —
это **не два разных API**, а два независимых слоя: inputs компонента управляют *составом*
графа, `rules`/`retry`/`needs` в YAML — *условиями запуска* существующих джобов.

```yaml
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/maven@1.0.0
    inputs:
      runtime_version: "21"
      service_type: image
      sonar: true          # добавить шаг в граф
      publish: false        # убрать шаг из графа

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

Поведение самого шага (команда сборки, хуки, реестры) настраивается отдельно, через
`.ci.yaml` или `HCI_*` — см. [§7](#7-справочник-конфигурации). Это разделение описано
в [DECISIONS.md §4](docs/DECISIONS.md#4-два-слоя-кастомизации-принято).

### Уровень 3 — свой граф из отдельных компонентов

Для нетипичных комбинаций (тест без публикации, несколько тестов с разными параметрами,
lint в параллель с build) — гранулярные компоненты, по одному джобу на файл:

```yaml
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/maven-build@$CI_COMMIT_SHA
    inputs:
      runtime_version: "21"
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/maven-test@$CI_COMMIT_SHA
    inputs:
      runtime_version: "21"

# Зависимости и условия — вручную, одним блоком на джоб
test:
  needs: [build]
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
```

Доступны гранулярно: `build`, `test`, `lint`, `publish`, `image:build`, `image:scan`,
`image:publish` на каждый рантайм (где применимо). Анализы/сканы (`deps:scan`, `sonar`,
`svace`, `appscreener`, `kcs`) и `cd:bump`/`cd:notify` остаются только внутри бандлов —
в уровне 2 они уже переключаются тумблером input, отдельные файлы под них не нужны
(и были бы лишним расходом дефицитного лимита компонентов на проект GitLab — см. §5).
Зависимость по цепочке: `image:scan`/`image:publish` требуют `image:build` в том же
`job_prefix`, иначе `log::die` на старте шага с явной диагностикой.

Эквиваленты для GitHub Actions и Jenkins — в [§5](#5-каждая-cicd-система).

---

## 4. Каждый рантайм

Общий список шагов на рантайм: `build`, `test` (где есть), `lint` (где есть), `publish`
(только `service_type: library`), `image:build`/`image:scan`/`image:publish` (только
`service_type: image`), плюс всегда доступные опциональные `deps:scan`, `sonar`, `svace`,
`appscreener`, `kcs`, `cd:bump`, `cd:notify` (выключены по умолчанию, кроме `deps:scan`).
Ниже — то, чем каждый рантайм отличается: версии, `service_type`, особые входы.

### bun

| | |
|---|---|
| **default_version** | `1` |
| **service_types** | `image`, `library` |
| **Особенность** | Публикация пакетов в npm registry при `service_type: library` |
| **Кэш** | `bun.lock`, `bun.lockb`, `node_modules` |

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
| **Доступные версии** | 3.1, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0 |
| **service_types** | `image`, `library` (nupkg в nuget-hosted) |
| **Особенность** | Svace-анализ поддержан (`svace: true`) |

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
| **Доступные версии** | 1.22, 1.25 |
| **service_types** | `image` (только; статический бинарник, нет library-публикации) |
| **Особенность** | Runtime-образ — `scratch` (минимальный, без publish в package registry); отчёт покрытия `cobertura` |

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
| **Доступные версии** | 8, 11, 17, 21, 25 |
| **service_types** | `image`, `library` |
| **Особенность** | JUnit + Jacoco-отчёты из коробки; `build.gradle`/`gradle.lockfile` в кэше |

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
| **Доступные версии** | 8, 11, 17, 21, 25 |
| **service_types** | `image`, `library` |
| **Профили** | `profile: quarkus` — альтернативный build/package flow для Quarkus-проектов |
| **Особенность** | JUnit (surefire+failsafe) + Jacoco; многомодульные проекты поддержаны |

```yaml
# GitLab — обычный Maven
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/maven@1.0.0
    inputs: { runtime_version: "21", service_type: image }

# GitLab — Quarkus-профиль
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/maven@1.0.0
    inputs: { runtime_version: "21", service_type: image, profile: quarkus }
```

### nodejs

| | |
|---|---|
| **default_version** | `22` |
| **Доступные версии** | 10, 12, 14, 16, 18, 20, 22 |
| **service_types** | `image`, `library` |
| **Особенность** | npm, yarn или pnpm (corepack) — автоопределение по lock-файлу; скрипты `build`/`test`/`lint` берутся из `package.json` |

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
| **Доступные версии** | 7.3, 7.4, 8.0, 8.1, 8.2, 8.3 |
| **service_types** | `image` (только) |
| **Особенность** | Composer + s2i (ubi-php); тесты — PHPUnit, нет `lint`/`publish` шагов |

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
| **Доступные версии** | 3.9, 3.11, 3.12, 3.13 |
| **service_types** | `image`, `library` (wheel/sdist в pypi-hosted) |
| **Особенность** | pip, uv, poetry или pdm — автоопределение; `service_type: image` упаковывает venv в образ |

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
| **service_types** | `image` (статический бинарник в `scratch`), `library` (публикация crate) |
| **Особенность** | Cargo; единственная доступная версия тулчейна на сегодня — 1.90 |

```yaml
# GitLab
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/rust@1.0.0
    inputs: { runtime_version: "190", service_type: image }
```

### static (статический сайт)

| | |
|---|---|
| **default_version** | `126` (nginx 1.26) |
| **service_types** | `image` (только) |
| **Особенность** | Сборка фронтенда (npm/yarn/pnpm, если есть `package.json`) и упаковка в nginx-образ через s2i; нет `test`/`publish` шагов. Зафиксирована одна версия (nginx 1.26) — схема помечена `versions: false`, выбор версии пользователю не предлагается |

```yaml
# GitLab
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/static@1.0.0
    inputs: { service_type: image }
```

### Прочие компоненты (не привязаны к рантайму)

Три дополнительных GitLab-компонента не относятся ни к одному рантайму — для случаев,
когда приложение уже собрано вне этого пайплайна или нужен только анализ/Helm:

| Компонент | Назначение |
|---|---|
| `image` | Образ из готового Containerfile/Dockerfile, CEKit или базового образа — без сборки приложения (`image:build` → `image:scan` → `image:publish`) |
| `helm` | Helm-чарт: `helm lint` + `kubeconform`, затем публикация в чарт-репозиторий |
| `analyze` | Анализы без сборки: `deps:scan`, `sonar`, `svace`, `appscreener` — на существующих исходниках |

```yaml
# GitLab — публикация уже готового образа
include:
  - component: $CI_SERVER_FQDN/$CI_PROJECT_PATH/image@1.0.0
    inputs: { workdir: . }
```

---

## 5. Каждая CI/CD-система

Единый контракт у всех трёх — `ci <step>`. Разница только в том, как система описывает
граф джобов и логику (ветки/retry/manual).

### GitLab CI/CD

Компоненты (`templates/*.yml`), подключаются через `include: component:`.
Лимит GitLab — максимум ~100 компонентов на проект; поэтому гранулярные компоненты
покрывают только `build/test/lint/publish/image:*`, а анализы/сканы/CD остаются в бандле
как input-тумблеры (см. §3, Уровень 3).

**Уровень 1/2** — см. примеры в §3 и §4 (один `include:` на бандл рантайма).

**Уровень 3 (гранулярно)**:

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

Подробности и полная таблица input-ов — [adapters/gitlab/README.md](adapters/gitlab/README.md).

### GitHub Actions

Composite action (`adapters/github/action.yml`) на один шаг, либо reusable workflow
(`pipeline.yml`) на весь граф.

**Уровень 1/2 (reusable workflow)**:

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

Другие условия publish — форкните `pipeline.yml` в свой репозиторий и правьте `if:` как
обычный Actions YAML (это не отдельный DSL — чистый GitHub Actions).

**Уровень 3 (гранулярно, через `step:` на composite action)**:

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

Подробности — [adapters/github/README.md](adapters/github/README.md).

### Jenkins

Shared library: `hci('build')` на один шаг, `hciPipeline(...)` на весь граф. Вся логика
ветвления — нативный Declarative/Scripted Groovy (`when`, `retry()`, `input`), без
отдельного DSL.

**Уровень 1/2 (hciPipeline)**:

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

**Уровень 3 (гранулярно, прямой вызов `hci()`)**:

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

Код **78** → `unstable` джоб (не красный, не зелёный). Подробности —
[adapters/jenkins/README.md](adapters/jenkins/README.md).

---

## 6. CD: `cd:bump` и `cd:notify` — на каждой CI-системе

Два независимых опциональных шага (по умолчанию выключены) для GitOps-деплоя:

- **`cd:bump`** — клонирует GitOps-репозиторий, правит один YAML-путь (image tag/digest)
  через `yq`, коммитит и пушит. При конфликте (`non-fast-forward`/`fetch first`) сам
  перезагружает ветку и переприменяет правку; при сетевой ошибке — просто повторяет push.
  Жёсткий отказ (не soft-exit 78) — ошибка деплоя не должна молча проглатываться.
- **`cd:notify`** — шлёт authenticated HTTP-вебхук GitOps-контроллеру (ArgoCD, Flux,
  произвольный endpoint). Если включены оба шага, `cd:notify` автоматически ждёт
  `cd:bump` (зависимость `optional: true` — включить только `cd:notify` тоже можно).

Оба по умолчанию запускаются только по тегу (как `image:publish`).

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

`pipeline.yml` (reusable workflow) **не имеет** входов `cd-bump`/`cd-notify` — в отличие
от GitLab-бандлов, он не заворачивает весь набор опциональных шагов (то же верно для
`svace`/`appscreener`/`kcs`/`helm:*`). Единственный способ вызвать `cd:bump`/`cd:notify`
на GitHub — добавить job, напрямую вызывающий composite action с нужным `step:`,
после job-а из `pipeline.yml`:

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

`hciPipeline(...)` тоже не содержит стадий `cd:bump`/`cd:notify` (как и `svace`/
`appscreener`/`kcs`/`helm:*`) — вызывайте `hci(step: 'cd:bump')` напрямую в своём
Jenkinsfile, за стадией `image:publish`:

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

### Общие замечания (все три системы)

- **HTTPS-токен**: укажите платформенный username в `HCI_CD_GIT_USER` —
  GitLab: `oauth2` (дефолт), GitHub App: `x-access-token`, Bitbucket Cloud: `x-token-auth`.
- **SSH-ключ**: `HCI_CD_GIT_SSH_KEY`/`HCI_CD_GIT_SSH_KNOWN_HOSTS` принимают путь к файлу
  или содержимое. В GitLab — объявляйте как **File**-тип переменной, не Masked
  (многострочные значения не маскируются).
- **Многодокументные YAML** (несколько `---`-манифестов в одном файле — Argo/Flux):
  `HCI_CD_YAML_PATH` обязан быть защищён `select()`:
  `(select(.kind=="Deployment").spec.template.spec.containers[0].image)`.
- **Секрет в URL вебхука**: не кладите `?token=...` в `HCI_CD_NOTIFY_URL` (эта переменная
  не маскируется — GitLab-маскирование отклоняет значения со `/`). Используйте
  `HCI_CD_NOTIFY_TOKEN`, он уходит как `Authorization: Bearer <токен>`.
- **kustomize не поддержан** — только прямая правка YAML-пути через `yq`. Типичный случай
  (`image:` в Deployment/values.yaml) полностью покрыт; `kustomize` потребовал бы отдельного
  бинаря в tools-образе — вне объёма текущей версии.

Полная документация CD (edge cases, troubleshooting) —
[docs/pipeline.md §CD](docs/pipeline.md#cd-cdbump-и-cdnotify).

---

## 7. Справочник конфигурации

### Все шаги (`ci help`)

| Шаг | Назначение | Soft-exit (78) при `strict: false` |
|-----|-----------|:---:|
| `build` | сборка (+ упаковка библиотеки при `service_type: library`) | — |
| `test` | модульные тесты с покрытием | ✅ |
| `lint` | линтеры | ✅ |
| `publish` | публикация библиотеки в реестр пакетов | — |
| `image:build` | сборка образа (`base`/`dockerfile`/`s2i`/`cekit`) | — |
| `image:scan` | анализ образа (Trivy) + SBOM | ✅ |
| `image:publish` | публикация, подпись, аттестация образа | — |
| `sbom` | SBOM образа отдельно | — |
| `deps:scan` | анализ зависимостей (Trivy fs) | ✅ |
| `sonar` | SonarQube | ✅ |
| `svace` | Svace | ✅ |
| `appscreener` | Solar appScreener | ✅ |
| `kcs` | Kaspersky Container Security | ✅ |
| `helm:lint` | проверка Helm-чарта | — |
| `helm:publish` | публикация Helm-чарта | — |
| `cd:bump` | бамп image-ref в GitOps-манифесте (git commit+push) | — (hard-fail) |
| `cd:notify` | webhook-триггер GitOps-контроллера | — (hard-fail) |

Служебные: `config` (итоговая конфигурация с маскированными секретами), `detect`
(определить рантайм/инструменты), `images` (образы build/runtime для текущего рантайма),
`manifest:validate`, `run -- <команда>` (выполнить произвольную команду в окружении
рантайма), `version`.

### Каскад конфигурации

1. CLI: `ci build --runtime-version=21`
2. Переменные окружения: `HCI_RUNTIME_VERSION=21`
3. `.ci.yaml` проекта
4. `core/runtimes/<rt>/defaults.env`
5. `core/defaults.env`

### `.ci.yaml` — пример

```yaml
runtime: maven
service_type: image
runtime_version: "21"
profile: none          # quarkus для Maven
strict: true
image:
  build_mode: auto      # auto | base | dockerfile | s2i | cekit
  platforms: [linux/amd64]
  context: target/*.jar
  labels: { team: payments }
build:
  cmd: mvn -q package   # полная замена шага
env:
  MAVEN_OPTS: "-Xmx1g"
```

Выключить шаг: `HCI_TEST_ENABLED=false` или input `test: false`.
Строгость: `HCI_STRICT` (глобально) и `HCI_TEST_STRICT` (точечно).

### Своя команда шага (`HCI_<ШАГ>_CMD`) — полная замена под нестандартную сборку

Для любого шага есть переменная `HCI_<ШАГ>_CMD` (имя шага в верхнем регистре, `:`/`-` → `_`:
`build` → `HCI_BUILD_CMD`, `image:build` → `HCI_IMAGE_BUILD_CMD`, `deps:scan` →
`HCI_DEPS_SCAN_CMD`). Если она задана, диспетчер (`core/lib/dispatch.sh`) не вызывает
встроенную реализацию рантайма — вместо неё выполняется `eval` над значением переменной:
инлайн-команда, `&&`-цепочка или путь к своему скрипту.

```yaml
# .ci.yaml — build.cmd автоматически превращается в HCI_BUILD_CMD
build:
  cmd: ./ci/my-weird-build.sh --target=embedded
```

Что при этом сохраняется:

- **Setup рантайма всё равно отрабатывает** — для шагов из `HCI_SETUP_STEPS` (`build`,
  `test`, `lint`, `publish`, `sonar`, `svace`) окружение (реестры, кэши, toolchain из
  образа) настраивается ДО вашей команды — в своём скрипте используется уже готовое
  окружение, а не собирается с нуля.
- **Код возврата трактуется так же**, как у встроенной логики: мягкие шаги (`test`,
  `lint`, `image:scan`, `deps:scan`, `sonar`, `svace`, `appscreener`, `kcs`) при
  `strict: false` дают soft-exit 78 вместо провала пайплайна, даже если команда своя.

Не путать с `HCI_IMAGE_CMD` (без `_BUILD_`) — это узкий параметр только для s2i-режима
внутри встроенного `image:build` (подменяет `/usr/libexec/s2i/run`), а не общий
override-механизм шага.

### Хуки — добавить, не заменяя

- Файлы `.ci/hooks/<step>.pre.sh` и `.post.sh` (`:` в имени шага заменяется на `-`,
  т.е. для `image:build` — `.ci/hooks/image-build.pre.sh`).
- Inline: `HCI_BUILD_PRE`, `HCI_BUILD_POST`, и аналогично для других шагов.

Хуки выполняются **вокруг** шага (до/после), не отключая встроенную реализацию или
`HCI_<ШАГ>_CMD` — для лёгкой доп. обработки (прогреть кэш, отправить метрику). Для полной
замены логики шага — `HCI_<ШАГ>_CMD` выше.

### Реестры

`HCI_REGISTRY_<TYPE>_{HOST,USER,PASSWORD,PULL_REPO,REPO}` для типов `OCI`, `OCI_PUSH`,
`MAVEN`, `NPM`, `NUGET`, `PYPI`, `CARGO`, `GO`, `HELM`, `COMPOSER`. Пустые значения
наследуют общие `HCI_REGISTRY_*` (которые по умолчанию берутся из `NEXUS_*`).

### CD-переменные (`cd:bump` / `cd:notify`)

| Переменная | Назначение | Дефолт |
|---|---|---|
| `HCI_CD_GIT_URL` | URL GitOps-репозитория (без userinfo!) | — |
| `HCI_CD_GIT_BRANCH` | целевая ветка | HEAD репозитория |
| `HCI_CD_GIT_TOKEN` | HTTPS-токен (через `GIT_ASKPASS`, не в URL) | — |
| `HCI_CD_GIT_USER` | username для HTTPS-токена | `oauth2` |
| `HCI_CD_GIT_SSH_KEY` / `HCI_CD_GIT_SSH_KNOWN_HOSTS` | путь или содержимое ключа/known_hosts | — |
| `HCI_CD_GIT_SSH_INSECURE` | пропустить проверку host key (не для прода) | `false` |
| `HCI_CD_GIT_USER_NAME` / `HCI_CD_GIT_USER_EMAIL` | автор коммита | `hyperion-ci` / `ci@localhost` |
| `HCI_CD_IMAGE` | явный image-ref вместо чтения из манифеста артефактов | — |
| `HCI_CD_YAML_FILE` | путь к файлу манифеста в GitOps-репо | — |
| `HCI_CD_YAML_PATH` | yq-путь до image-поля (используйте `select()` для multi-doc) | — |
| `HCI_CD_NOTIFY_URL` | URL вебхука (не маскируется — не кладите секрет в query!) | — |
| `HCI_CD_NOTIFY_METHOD` | HTTP-метод | `POST` |
| `HCI_CD_NOTIFY_TOKEN` | Bearer-токен для вебхука | — |
| `HCI_CD_NOTIFY_BODY` | тело запроса | — |
| `HCI_CD_NOTIFY_TIMEOUT` | таймаут запроса, сек | `30` |

### Закрытый контур (air-gapped)

Пайплайн рассчитан на работу без прямого доступа в публичный интернет — почти всё уже
адресуется через внутренние реестры/серверы по умолчанию или через конфигурацию:

| Что | Как уже устроено |
|---|---|
| Образы сборки/рантайма/sonar/svace | Всегда через `${HCI_REGISTRY_OCI_HOST}/${HCI_IMAGES_FOLDER}/...` (meta.yaml) — ожидают внутренний реестр, не Docker Hub/GHCR |
| Пакетные реестры (maven/npm/pip/…) | `HCI_REGISTRY_<TYPE>_*` → внутренний Nexus-прокси, см. [§Реестры](#реестры) |
| SonarQube | `HCI_SONAR_HOST_URL` (из `SONAR_HOST`) — всегда внутренний сервер, сканер никогда не ходит в интернет |
| Trivy | По умолчанию **server-режим**: `HCI_TRIVY_SERVER` = `http://trivy:8080` — БД уязвимостей обновляет сервер, не джоб |

**Trivy standalone** (если `HCI_TRIVY_SERVER` пуст — нет центрального Trivy-сервера):
без сервера Trivy сам тянет БД с `ghcr.io/aquasecurity` на каждом скане. Чтобы вместо
этого использовать внутреннее зеркало БД:

```bash
HCI_TRIVY_SERVER=""                                            # отключить server-режим
HCI_TRIVY_DB_REPOSITORY="internal.example/mirror/trivy-db"
HCI_TRIVY_JAVA_DB_REPOSITORY="internal.example/mirror/trivy-java-db"
```

Обе переменные пусты по умолчанию — поведение Trivy (дефолт на `ghcr.io`) не меняется,
пока их не задать явно.

**`jq`/`yq` в tools-образе** — единственное место с хардкодом на публичный интернет,
но это **не раннее исполнение пайплайна проекта**, а разовая сборка wrapper-образа
(`tools/fetch-binaries.sh`, вызывается при сборке `/opt/ci`-образа, не на каждый коммит
сервиса). Переопределяется через env на этапе сборки образа:

```bash
JQ_URL="https://nexus.internal/raw/jq-1.7.1-linux-amd64" \
YQ_URL="https://nexus.internal/raw/yq_v4.44.3_linux_amd64" \
  bash tools/fetch-binaries.sh
```

Без переопределения — дефолт на `github.com/jqlang/jq` и `github.com/mikefarah/yq`
(те же файлы, просто без зеркала).

### Манифест артефактов

`hci-artifacts/artifacts.json`, схема `core/schema/artifacts.v2.json`. Пишется только
через `manifest::add`. Проверка: `ci manifest:validate`.

### Локальный запуск (без CI)

```bash
export PATH="$PWD/core/bin:$PATH"
ci detect
ci build --runtime=maven --workdir=tests/fixtures/maven-service
ci help
```

### Генерация GitLab-компонентов

```bash
python3 tools/generate.py          # регенерировать templates/*.yml, wrappers, schema.yaml
python3 tools/generate.py --check  # в CI: падает, если артефакты устарели
```

Руками `templates/*.yml` не редактируется — только `core/runtimes/*/meta.yaml` +
`tools/generate.py`.
