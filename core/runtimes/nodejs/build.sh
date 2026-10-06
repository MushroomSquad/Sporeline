# shellcheck shell=bash
rt::build() {
  node::install
  if ci::is_true "${HCI_NODE_SKIP_BUILD:-false}"; then
    log::info "HCI_NODE_SKIP_BUILD=true, build skipped"
    return 0
  fi
  node::has_script "${HCI_NODE_BUILD_SCRIPT:-build}" || log::die "No '${HCI_NODE_BUILD_SCRIPT:-build}' script in package.json. Set HCI_NODE_BUILD_SCRIPT or HCI_NODE_SKIP_BUILD=true"
  node::run_script "${HCI_NODE_BUILD_SCRIPT:-build}"
}
