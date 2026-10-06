#!/usr/bin/env bash
# Shared core step runner invoked from CI adapters.
# Usage: run-step.sh <step> [--key=value ...]
# Code 78 (a soft step under HCI_STRICT=false) → warning and exit 0.
# Any other non-zero code is passed through as-is.
set -uo pipefail

step="${1:-}"
[[ -n "$step" ]] || { echo "Использование: run-step.sh <шаг> [аргументы ci...]" >&2; exit 2; }
shift

ci_bin="${HCI_CI_BIN:-ci}"
if [[ "$ci_bin" == */* && ! -x "$ci_bin" && -x "${GITHUB_WORKSPACE:-}${GITHUB_WORKSPACE:+/}$ci_bin" ]]; then
  ci_bin="${GITHUB_WORKSPACE}/$ci_bin"
fi
if [[ "$ci_bin" == */* ]]; then
  _hci_bin_dir="$(cd "$(dirname "$ci_bin")" && pwd)"
  export PATH="${_hci_bin_dir}:${PATH:-}"
  unset _hci_bin_dir
fi

set +e
"$ci_bin" "$step" "$@"
rc=$?
set -e

soft="${HCI_SOFT_EXIT_CODE:-78}"
if [[ "$rc" -eq "$soft" ]]; then
  msg="hci $step: мягкий отказ (код $soft), пайплайн не блокируется"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning::$msg"
  elif [[ -n "${JENKINS_URL:-}" ]]; then
    echo "[WARNING] $msg"
  else
    echo "warn: $msg" >&2
  fi
  exit 0
fi
exit "$rc"
