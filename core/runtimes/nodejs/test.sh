# shellcheck shell=bash
rt::test() {
  local script="${HCI_NODE_TEST_SCRIPT:-test:coverage}" resolved=""
  if node::has_script "$script"; then
    resolved="$script"
  elif [[ "$script" == "test:coverage" ]] && node::has_script test; then
    resolved="test"
  elif node::has_script test; then
    resolved="test"
  elif node::has_script test:coverage; then
    resolved="test:coverage"
  fi
  [[ -n "$resolved" ]] || ci::skip "no test script in package.json (HCI_NODE_TEST_SCRIPT=$script)"
  node::run_script "$resolved"
}
