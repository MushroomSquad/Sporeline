[English](README.md) | [Русский](README.ru.md)

# CI Adapters

One contract for every system: **`ci <step>`**. An adapter only describes the job graph
and passes `HCI_*` through.

| Adapter | Artifacts | Docs |
|---------|-----------|--------------|
| **GitLab** | `templates/*.yml` (CI/CD components) | [gitlab/README.md](gitlab/README.md) |
| **GitHub Actions** | `github/action.yml`, `github/pipeline.yml` | [github/README.md](github/README.md) |
| **Jenkins** | `jenkins/vars/hci.groovy`, `hciPipeline.groovy` | [jenkins/README.md](jenkins/README.md) |

Shared soft-exit wrapper: [common/run-step.sh](common/run-step.sh) (code **78** →
warning / unstable).

Platform variable normalization — `core/lib/ci-env.sh` (`gitlab` / `github` / `jenkins` /
`local`).

Pipeline logic (branches, retry, when): [docs/pipeline.md](../docs/pipeline.md) — the
project's YAML / Jenkinsfile.

Decisions and design history: [docs/DECISIONS.md](../docs/DECISIONS.md).
