# Адаптеры CI

Один контракт для всех систем: **`ci <step>`**. Адаптер описывает только граф джобов и передаёт `HCI_*`.

| Адаптер | Артефакты | Документация |
|---------|-----------|--------------|
| **GitLab** | `templates/*.yml` (CI/CD components) | [gitlab/README.md](gitlab/README.md) |
| **GitHub Actions** | `github/action.yml`, `github/pipeline.yml` | [github/README.md](github/README.md) |
| **Jenkins** | `jenkins/vars/hci.groovy`, `hciPipeline.groovy` | [jenkins/README.md](jenkins/README.md) |

Общая обёртка soft-exit: [common/run-step.sh](common/run-step.sh) (код **78** → warning / unstable).

Нормализация переменных платформы — `core/lib/ci-env.sh` (`gitlab` / `github` / `jenkins` / `local`).

Логика пайплайна (ветки, retry, when): [docs/pipeline.md](../docs/pipeline.md) — YAML проекта / Jenkinsfile.

Решения и история дизайна: [docs/DECISIONS.md](../docs/DECISIONS.md).
