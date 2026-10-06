# shellcheck shell=bash
rt::lint() {
  [[ -f package.json ]] || ci::skip "нет package.json"
  # shellcheck source=/dev/null
  source "$HCI_HOME/runtimes/nodejs/lib.sh"
  source "$HCI_HOME/runtimes/nodejs/lint.sh"
  node::setup
  node::lint
}
