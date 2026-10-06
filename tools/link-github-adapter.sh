#!/usr/bin/env bash
# Sets up the paths GitHub expects (workflows/actions) from adapters/github.
# Run from the templates repository root before publishing a tag.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/.github/workflows" "$root/.github/actions/hci"
ln -sfn ../../adapters/github/pipeline.yml "$root/.github/workflows/hci.yml"
ln -sfn ../../../adapters/github/action.yml "$root/.github/actions/hci/action.yml"
ln -sfn ../../../adapters/github/run-step.sh "$root/.github/actions/hci/run-step.sh"
echo "Done:"
ls -la "$root/.github/workflows/hci.yml" "$root/.github/actions/hci/"
