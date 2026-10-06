# shellcheck shell=bash
# Общая обвязка bats-тестов ядра.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
export HCI_HOME="$REPO_ROOT/core"
export HCI_TEST_BIN="$HCI_HOME/bin/ci"

hci_clean_env() {
  local name
  for name in $(compgen -e | grep -E '^(HCI_|GITLAB_CI|GITHUB_|JENKINS_URL|CI_|NEXUS_|REGISTRY_|CUSTOM_CA)' | grep -vE '^(HCI_HOME|HCI_TEST_BIN)$' || true); do
    unset "$name"
  done
  export HCI_HOME="$REPO_ROOT/core"
}

hci_setup_workdir() {
  hci_clean_env
  WORKDIR="$(mktemp -d)"
  cd "$WORKDIR" || return 1
  git init -q
  git config user.email t@t
  git config user.name t
  git remote add origin https://gitlab.local/group/sub/project.git
  export NO_COLOR=1
}

hci_teardown_workdir() {
  cd / || true
  [[ -n "${WORKDIR:-}" ]] && rm -rf "$WORKDIR"
}

# Подключает библиотеки ядра в текущий shell теста.
hci_source_libs() {
  local f
  for f in "$HCI_HOME"/lib/*.sh; do
    # shellcheck source=/dev/null
    source "$f"
  done
  HCI_TMP="$(mktemp -d)"
  export HCI_TMP
}
