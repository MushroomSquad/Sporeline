# shellcheck shell=bash
rt::publish() {
  # shellcheck source=/dev/null
  source "$HCI_HOME/runtimes/nodejs/lib.sh"
  node::publish
}
