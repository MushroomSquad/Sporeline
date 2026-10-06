[English](README.md) | Русский

# GitLab CI/CD — адаптер

Компоненты — тонкий YAML-граф над ядром `ci <step>`. Файлы в `templates/`.

```bash
python3 tools/generate.py
python3 tools/generate.py --check
```

Не править `templates/*.yml` руками (кроме осознанного форка).

**Логика пайплайна** (ветки, retry, manual, OR/AND) — в `.gitlab-ci.yml` проекта:
см. [docs/pipeline.md](../../docs/pipeline.ru.md).

## Подключение

```yaml
include:
  - component: $CI_SERVER_FQDN/<group>/templates/maven@1.0.0
    inputs:
      runtime_version: "21"
      service_type: image
      profile: none
      workdir: .
      job_prefix: ""
      strict: true
      test: true
      image_build: true
      image_scan: true
      image_publish: true
      publish: true
      deps_scan: true
      sonar: false
      svace: false
      appscreener: false
      kcs: false

# пример кастомизации логики — обычный GitLab YAML:
workflow:
  rules:
    - if: $CI_COMMIT_BRANCH =~ /^(main|develop)$/
    - if: $CI_COMMIT_TAG

image:publish:
  rules:
    - if: $CI_COMMIT_TAG
    - if: $CI_COMMIT_BRANCH == "main"
      when: manual
```

## Граф джобов (дефолт)

- `lint`, `deps:scan`, `svace`, `appscreener` — `needs: []`
- `build` — корень DAG
- `test`, `sonar` — после `build`
- `image:build` → `image:scan` / `kcs` → `image:publish` (tag)
- `publish` — library + tag

Мягкие шаги: `allow_failure: exit_codes: [78]`.

## Гранулярные компоненты

Для полностью кастомного графа из отдельных компонентов см. [Уровень 3](../../docs/pipeline.ru.md#уровень-3-свой-граф-из-отдельных-компонентов):

```yaml
include:
  - component: $CI_SERVER_FQDN/<group>/templates/maven-build@$CI_COMMIT_SHA
  - component: $CI_SERVER_FQDN/<group>/templates/maven-test@$CI_COMMIT_SHA
```
