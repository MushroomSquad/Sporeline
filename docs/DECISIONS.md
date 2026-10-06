# Решения и история дизайна

Документ фиксирует договорённости из рабочей сессии по переписыванию CI-шаблонов
(`templates-master`). Это не changelog коммитов, а **что решили и почему**, включая отвергнутые пути.

Связанные доки:

- [pipeline.md](pipeline.md) — как кастомизировать логику пайплайна сейчас
- [../README.md](../README.md) — быстрый старт
- [../adapters/README.md](../adapters/README.md) — GitLab / GitHub / Jenkins

---

## 1. Исходный запрос

- Разобрать старые GitLab-шаблоны, убрать агентские инструкции (`AGENTS.md`, `.cursor/`).
- Расширить языки (в т.ч. Python), оптимизировать, больше кастомизации и вариативности.
- Greenfield OK; позже порт на GitHub / Jenkins.
- Ядро — bash (`bash_lib` → `core/`), запекается в образы (`/opt/ci`).
- Платформенный контракт артефактов можно пересмотреть.

Позже: довести адаптеры, объяснить кастомизацию пайплайна; вопросы про стадии в UI,
ветвление, retry, логические операторы → попытка «полноценного конструктора» → откат.

---

## 2. Архитектура ядра (принято)

| Решение | Выбор | Зачем |
|---------|--------|--------|
| Язык ядра | Bash CLI `ci <step>` | Уже был bash в YAML; переносится в образ; без отдельного рантайма Go/Python в каждом job |
| Доставка ядра | Образ с `/opt/ci`, тег `…-ci{VERSION}` | GitLab `include: project` не тянет соседние скрипты |
| Префикс env | `HCI_*` (не `CI_*`) | Не конфликтовать с переменными GitLab |
| Конфиг | CLI → env → `.ci.yaml` → runtime defaults → `core/defaults.env` | Предсказуемый приоритет |
| Мягкий отказ | exit **78** | Тесты/линтеры/сканы не валят пайплайн при `strict=false`; адаптер мапит в allow_failure / warning / unstable |
| Skip | exit **86** (где используется) | Явный пропуск шага |
| Профили | `HCI_PROFILE` (напр. maven/quarkus) | Вариативность внутри рантайма |
| Манифест | `hci-artifacts/artifacts.json` v2 | Единый контракт артефактов |
| Retry в ядре | `retry.sh` для сети/push | Не путать с job-level retry CI |

**Адаптеры** — тонкие: только граф джобов и вызов `ci <step>`.

- GitLab: CI/CD components в `templates/`
- GitHub: composite + reusable workflow
- Jenkins: shared library `hci` / `hciPipeline`

---

## 3. Генератор `tools/generate.py` (принято, узкая роль)

**Зачем есть:** не копипастить почти одинаковые GitLab-компоненты на ~10 рантаймов
(различия — версии образов, cache, junit/coverage, список шагов из `meta.yaml`).
Плюс: e2e-матрица, wrappers образов, `schema.yaml` (каталог flow/runtime).

**Зачем не нужен:** логика пайплайна (ветки, when, retry, OR/AND). На это генератор
не претендует.

Если устраивает ручной YAML на каждый рантайм — генератор можно удалить; на модель
«логика в проекте» это не влияет.

Руками `templates/*.yml` не править при живом генераторе — только `meta.yaml` + `generate.py`.

---

## 4. Два слоя кастомизации (принято)

Разделить то, что часто смешивали:

| Слой | Где | Что |
|------|-----|-----|
| **Поведение шага** | `.ci.yaml`, `HCI_*_CMD`, hooks, `strict` | *как* собирать / тестировать / публиковать |
| **Логика пайплайна** | YAML/Groovy **проекта** | *когда* джоб есть: ветки, sources, changes, retry, manual, OR/AND |

Тумблеры шагов в component inputs (`test: false`, `sonar: true`) — удобство, не замена `rules`.

---

## 5. Логика пайплайна = YAML проекта (принято)

Приоритет: **максимальная кастомизируемость и настраиваемость**.

- Конструктор логики — **обычный GitLab CI YAML** в репозитории сервиса
  (`workflow:rules`, override `build`/`test`/`image:publish` с своими `rules`/`retry`/`needs`).
- GitHub — `on:` / `if:` в вызывающем workflow (или форк `pipeline.yml`).
- Jenkins — `when {}`, `retry()`, `input` в Jenkinsfile / Groovy.

Дефолт в шаблоне минимальный: enabled + `service_type` + publish по тегу.
Всё сложнее — override в проекте. Подробности: [pipeline.md](pipeline.md).

**Шаблоны + reuse** повышают кастомизацию только если шаблон **тонкий**
(переиспользуются шаги/`ci`, а не монолитный «умный» пайплайн). Толстый шаблон
с зашитой политикой — кастомизацию режет.

---

## 6. Отвергнуто / откатано

### 6.1. «Полноценный конструктор» внутри генератора

Было сделано и **снято**:

- inputs: `branches`, `except_branches`, `pipeline_sources`, `changes`, `job_retry`, `publish_mode`
- «умный» `rules()` с `$HCI_BRANCHES` / OR-списком под `publish_mode`
- блок `constructor` в `schema.yaml` под виджеты UI
- паритет этих пресетов в GitHub/Jenkins

**Почему отвергнуто:** это не YAML-конструктор, а Python + промежуточные переменные;
кастомизация ограничена пресетами; непонятно «какой UI».

### 6.2. Платформенный веб-UI / «витрина»

`schema.yaml` как контракт для рисования формы в платформе **не цель** текущего дизайна.
Не проектируем и не обещаем UI. Каталог `schema.yaml` может оставаться для внешних
потребителей flow/runtime — без блока constructor и без привязки к «конструктору».

### 6.3. Свободный DSL выражений в inputs

Не делаем: пользовательские `||`/`if`-строки через inputs компонента.
Логика — нативный YAML CI / Groovy.

### 6.4. Job-retry и branch-policy в bash-ядре

Политика «на каких ветках бежать» и retry джоба — зона CI YAML/Groovy, не `core/`.
В ядре остаётся только сетевой `retry.sh` и нормализация `HCI_BRANCH` / `HCI_IS_MR` как env.

---

## 7. Старый мир → новый (миграция смыслов)

| Было | Стало |
|------|--------|
| `include: project: … Maven.gitlab-ci.yml` | `include: component: …/maven@tag` |
| `STAGE_TEST` и др. | input `test:` / override `rules` |
| `SERVICE_TYPE` | `service_type` |
| `JDK_VERSION` / runtime version vars | `runtime_version` |
| Логика в кусках `default/` + `buildah/` + runtime YAML | граф в component; поведение в `core/` |
| Inline shell в `script:` | `ci <step>` из образа |

Автомиграцию всех потребительских `.gitlab-ci.yml` не делали — только смысл маппинга.

---

## 8. Что в репозитории сейчас (снимок модели)

```
core/                 # ci, lib, steps, runtimes/*/meta.yaml
templates/            # GitLab components (из generate.py)
adapters/
  gitlab/             # доки; сами yml в templates/
  github/             # action + pipeline.yml
  jenkins/            # vars/hci.groovy, hciPipeline.groovy
  common/run-step.sh
tools/generate.py     # DRY рантаймов + e2e + wrappers + schema
docs/pipeline.md      # как писать логику в проекте
docs/DECISIONS.md     # этот файл
images/               # Containerfile'ы, wrappers CI
tests/                # bats, fixtures, e2e include
```

---

## 9. Краткие ответы на вопросы сессии

**«В веб-интерфейсе не отображаются стадии?»**  
В шаблонах стадии GitLab есть (`stage_*` inputs). Отдельного UI конструктора нет и не цель.

**«Ветвление / повторы / логические операторы?»**  
В проектном YAML (или Groovy). Не в генераторе.

**«Зачем генератор?»**  
Только DRY почти одинаковых runtime-компонентов и вспомогательная генерация.
Не для логики пайплайна.

**«Reuse темплейтов повысит кастомизацию?»**  
Только при тонких шаблонах и явных точках расширения. Иначе — наоборот.

---

## 10. Принципы на дальше

1. Тонкий адаптер, толстое ядро шагов.
2. Логика пайплайна — в языке CI пользователя (YAML / Groovy).
3. Не прятать политику запуска за «умными» inputs.
4. Не обещать платформенный UI из этого репозитория.
5. Генератор — опциональное удобство, не источник правды для rules.
