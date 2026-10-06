# shellcheck shell=bash
rt::setup() {
  [[ -f package.json ]] || return 0
  # shellcheck source=/dev/null
  source "$HCI_HOME/runtimes/nodejs/lib.sh"
  node::setup
}

rt::detect_tools() {
  printf 'static=nginx\n'
}
