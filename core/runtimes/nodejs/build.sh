# shellcheck shell=bash
rt::build() {
  node::install
  if ci::is_true "${HCI_NODE_SKIP_BUILD:-false}"; then
    log::info "HCI_NODE_SKIP_BUILD=true, сборка пропущена"
    return 0
  fi
  node::has_script "${HCI_NODE_BUILD_SCRIPT:-build}" || log::die "В package.json нет скрипта '${HCI_NODE_BUILD_SCRIPT:-build}'. Задайте HCI_NODE_BUILD_SCRIPT или HCI_NODE_SKIP_BUILD=true"
  node::run_script "${HCI_NODE_BUILD_SCRIPT:-build}"
}
