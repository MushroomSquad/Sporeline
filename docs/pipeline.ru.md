[English](pipeline.md) | Русский

# Конструктор логики пайплайна

Логика (ветки, when, retry, OR/AND, manual) живёт **в YAML проекта** — не в генераторе шаблонов.
Для Jenkins — в `Jenkinsfile` / shared-library вызове (Groovy).

Контекст решений: [DECISIONS.md](DECISIONS.md).

Компонент даёт только тонкий DAG: джобы → `ci <step>`. Дефолтные `rules` минимальные
(вкл/выкл шага, `service_type`, publish по тегу). Всё остальное — override.

## Уровни использования

Пайплайн можно строить тремя способами, в порядке возрастания гибкости:

- **Уровень 1** — быстрый старт готовым пайплайном. Подключить компонент (`include: component: …/maven@tag`), выбрать рантайм и сервис-тип (образ или библиотека). Дефолтный граф из документации ниже. Уже описано в [README.md](../README.md).

- **Уровень 2** — кастомизация готового пайплайна. Включить/выключить отдельные шаги (`test: false`, `sonar: true`), передать параметры (версия рантайма, реестры через `.ci.yaml` / `HCI_*`), переопределить логику в YAML проекта (`rules`, `needs`, `retry`, `when`). Это то, что описано в текущем содержимом этого документа: [GitLab](#gitlab-gitlab-ciml--конструктор), [GitHub](#github-actions), [Jenkins](#jenkins).

- **Уровень 3** — собственный граф из отдельных компонентов. Для нетипичных комбинаций шагов: например, несколько тестов с разными параметрами, lint в параллель, publish без сборки образа. Включить только нужные шаги (`maven-build`, `maven-test`, `image:scan`), задать зависимости вручную. Подробно: [Уровень 3](#уровень-3-свой-граф-из-отдельных-компонентов) ниже.

## GitLab: `.gitlab-ci.yml` = конструктор

```yaml
include:
  - component: $CI_SERVER_FQDN/<group>/templates/maven@1.0.0
    inputs:
      runtime_version: "21"
      service_type: image
      test: true
      sonar: false
      image_publish: true

# --- логика ниже: обычный GitLab CI YAML ---

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

# выключить джоб полностью
sonar:
  rules:
    - when: never
```

Имена джобов = имена шагов (`build`, `test`, `image:publish`, …).
С `job_prefix: "svc:"` → `svc:build`, `svc:test`, …

### Что можно переопределить

Любое поле джоба GitLab: `rules`, `retry`, `needs`, `when`, `only`/`except` (legacy),
`interruptible`, `tags`, `image`, `before_script`, `after_script`, `artifacts`, …

Inputs компонента — удобные тумблеры шагов и параметры рантайма, не замена `rules`.

### Поведение шага (не граф)

Команды, хуки, реестры — `.ci.yaml` / `HCI_*` (ядро `ci <step>`). Это отдельно от логики пайплайна.

## GitHub Actions

Reusable workflow — тонкий граф. Логика — в вызывающем workflow:

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
    # условия — на уровне jobs.<id>.if у caller, или forks workflow
```

Скопируйте `pipeline.yml` в свой репозиторий и правьте `if:` / `on:` как обычный Actions YAML.

## Jenkins

Конструктор — Groovy (`Jenkinsfile` или обёртка над `hciPipeline`):

```groovy
hciPipeline(
  runtime: 'maven',
  runtimeVersion: '21',
  buildImage: '…',
  toolsImage: '…',
)

// или свой pipeline { stages { when { branch 'main' }; steps { hci('build') } } }
```

`when { }`, `retry()`, `input` — стандартный Declarative/Scripted Jenkins, без отдельного DSL.

## Уровень 3: свой граф из отдельных компонентов

### Какие шаги доступны гранулярно?

Отдельные компоненты для каждого рантайма: `build`, `test`, `lint`, `publish` и образ — `image:build`, `image:scan`, `image:publish`. Эти шаги часто комбинируются нетипичными графами (например, тест без публикации, или несколько `test` с разными параметрами).

Анализы и сканы — `deps:scan`, `sonar`, `svace`, `appscreener`, `kcs` — остаются только в бандлах (`analyze.yml`, `image.yml`). В практике они всегда включаются/выключаются пачкой через входные переменные уровня 2, не собираются поштучно. Это не потеря функциональности (уровень 2 уже даёт переключение каждого тумблером), а экономия дефицитного ресурса компонентов.

**Цепочка зависимостей:**
- `lint`, `deps:scan`, `appscreener`, `svace` независимы от `build` (работают на исходниках)
- `test`, `sonar`, `publish`, `image:build` требуют `build`
- `image:scan`, `kcs`, `image:publish` требуют `image:build` транзитивно

### Рецепты по CI-системам

#### GitLab: гранулярные компоненты

```yaml
include:
  - component: $CI_SERVER_FQDN/<group>/templates/maven-build@$CI_COMMIT_SHA
    inputs:
      runtime_version: "21"
  - component: $CI_SERVER_FQDN/<group>/templates/maven-test@$CI_COMMIT_SHA
    inputs:
      runtime_version: "21"

# Укажите зависимости и условия вручную — одним блоком, не отдельными `test:`,
# иначе второй ключ в YAML молча затрёт первый
test:
  needs:
    - build
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
      changes:
        - src/**/*
```

Замечание: все гранулярные компоненты одного `job_prefix` должны использовать один и тот же `job_prefix` (как и в бандлах) — иначе `needs:` не найдёт правильное имя джоба.

#### GitHub Actions: гранулярные компоненты

Composite action `action.yml` поддерживает вызовы отдельных шагов через входную переменную `step`:

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

#### Jenkins: гранулярные компоненты

Вызовите шаги напрямую из своего `Jenkinsfile`, минуя `hciPipeline()`:

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

### Зависимости гранулярных файлов

Компоненты, требующие логических предшественников:

| Компонент | Требует | Что произойдёт без требуемого |
|-----------|---------|-------------------------------|
| `*-image-scan.yml` | `*-image-build.yml` в том же `job_prefix` | `log::die` в момент запуска на отсутствующую директорию OCI образа |
| `*-image-publish.yml` | `*-image-build.yml` в том же `job_prefix` | `log::die` в момент запуска на отсутствующую директорию OCI образа |

Ошибка мгновенная (выполняется в `script:` шага), название артефакта явное, диагностика самопояснительна.

### Дефолты гранулярных файлов

Гранулярные компоненты используют более узкий дефолт, чем бандлы:
- Нет `HCI_JOB_ENABLED` — сам выбор файла компонента это сигнал включения
- Нет `service_type`-ворот — работают для всех типов сервиса
- Publish-джобы (`*-publish.yml`, `*-image-publish.yml`) по-прежнему запускаются только по тегу (правило `tag_only`)

## CD: `cd:bump` и `cd:notify`

### `cd:bump`

Обновляет GitOps-манифесты: клонирует репозиторий, редактирует один YAML-путь (image-тег или digest) через `yq`, коммитит и пушит в ветку. При конфликте слияния автоматически перезагружает remote-ветку и пересчитывает правку. Опциональный шаг (выключен по умолчанию), падает при ошибке (hard-fail). Запускается по тегу по умолчанию (правило `rules: image_only, tag_only`, как `image:publish`).

### `cd:notify`

Отправляет HTTP-вебхук (authenticated) для уведомления GitOps-контроллера об обновлении. Поддерживает любой HTTP-приёмник: ArgoCD, Flux notification-controller, кастомные. Опциональный шаг (выключен по умолчанию), hard-fail, запускается по тегу по умолчанию. Если включены оба шага, `cd:notify` автоматически дождётся `cd:bump` (зависимость проводится автоматически генератором с `optional: true`, так что включение только `cd:notify` без `cd:bump` работает при желании).

### Использование двух шагов вместе

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

### Учётные данные и доступ

#### Переменная `HCI_CD_GIT_USER` по платформам

При использовании HTTPS с токеном укажите платформенный username в `HCI_CD_GIT_USER`:

| Платформа | `HCI_CD_GIT_USER` |
|---|---|
| GitLab | `oauth2` (дефолт) |
| GitHub App | `x-access-token` |
| Bitbucket Cloud | `x-token-auth` или реальный username |

#### SSH-ключи и known_hosts

Переменные `HCI_CD_GIT_SSH_KEY` и `HCI_CD_GIT_SSH_KNOWN_HOSTS` принимают либо путь до файла, либо содержимое.

**Рекомендация**: объявите их как GitLab **File**-тип CI/CD переменные (не Masked). Причина — GitLab-маскирование не поддерживает многострочные значения; приватный SSH-ключ из нескольких строк и `known_hosts`-блок попросту не маскируются при попытке сохранить как Masked-переменную. File-переменная даёт шагу путь к файлу в контейнере, избегая этой проблемы:

```yaml
# В GitLab CI/CD Settings → Variables:
# HCI_CD_GIT_SSH_KEY (тип File) = загрузить приватный ключ
# HCI_CD_GIT_SSH_KNOWN_HOSTS (тип File) = загрузить known_hosts
```

### Многодокументные YAML-манифесты

Если целевой файл манифестов содержит несколько документов, разделённых `---` (частый случай в Argo CD / Flux репозиториях — Service + Deployment в одном файле), `HCI_CD_YAML_PATH` должен быть защищён `select()`-выражением. Иначе путь может случайно совпасть и на чужом документе в том же файле, что приведёт к ошибке гейта.

Правильный пример:

```bash
HCI_CD_YAML_PATH='(select(.kind=="Deployment").spec.template.spec.containers[0].image)'
```

Выражение вернёт image-путь **только** из блока с `kind: Deployment`, игнорируя соседние Service-документы.

### Вебхуки и токены

`HCI_CD_NOTIFY_URL` **не маскируется** автоматически. Причина: GitLab-маскирование отклоняет значения, содержащие `/`, а в URL всегда есть `/`. Эта же переменная не перехватывается собственным regex-редактором проекта (`log::redact`).

Если вебхук требует секрет (распространённый паттерн вида `?token=...` в query-string), **не кладите секрет в сам URL**. Используйте вместо этого `HCI_CD_NOTIFY_TOKEN` — он отправляется как `Authorization: Bearer <токен>` и защищен от утечек в лог:

```bash
# Плохо:
HCI_CD_NOTIFY_URL='https://webhook.example.com/hook?token=secret123'

# Хорошо:
HCI_CD_NOTIFY_URL='https://webhook.example.com/hook'
HCI_CD_NOTIFY_TOKEN='secret123'  # отправляется в Authorization-заголовке
```

### Пограничные случаи

**Если включен `cd_notify: true`, но `cd_bump: false` и `image_publish: false` без явного `HCI_CD_IMAGE`:** пайплайн не собирается (ошибка на уровне генератора — needs на несуществующие шаги). Это необычная конфигурация; если вы её встретили, проверьте логику вашего пайплайна вручную. Решение — либо включить `image_publish`, либо задать `HCI_CD_IMAGE` явно для override из другого источника.

### Non-Goal: `kustomize`

Редактирование манифестов через `kustomize` **не поддерживается** в этой версии. Бинарь `kustomize` отсутствует в tools-образе проекта (подтверждено в `tools/fetch-binaries.sh` — только `yq`). Добавление поддержки `kustomize` требует расширения `tools/fetch-binaries.sh` и пересборки tools-образа — это отдельная задача, не входящая в данное изменение. Прямое редактирование YAML-пути через `yq` полностью покрывает типичный случай (поле `image:` в Deployment / values.yaml).

## Слои (кратко)

| Слой | Где | Ответственность |
|------|-----|-----------------|
| Граф по умолчанию | `templates/*.yml` (generate) | джобы + `ci <step>`, минимальные rules |
| Логика пайплайна | **YAML/Groovy проекта** | ветки, retry, manual, OR/AND, changes |
| Поведение шага | `.ci.yaml` / env / hooks | build/test/publish команды |
