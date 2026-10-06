#!/usr/bin/env bash
# Готовит пути, которые ожидает GitHub (workflows/actions), из adapters/github.
# Запускать из корня репозитория шаблонов перед публикацией тега.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/.github/workflows" "$root/.github/actions/hci"
ln -sfn ../../adapters/github/pipeline.yml "$root/.github/workflows/hci.yml"
ln -sfn ../../../adapters/github/action.yml "$root/.github/actions/hci/action.yml"
ln -sfn ../../../adapters/github/run-step.sh "$root/.github/actions/hci/run-step.sh"
echo "Готово:"
ls -la "$root/.github/workflows/hci.yml" "$root/.github/actions/hci/"
