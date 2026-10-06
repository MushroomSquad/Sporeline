# shellcheck shell=bash
rt::test() {
  if [[ -n "${HCI_BUN_TEST_SCRIPT:-}" ]]; then
    bun::has_script "$HCI_BUN_TEST_SCRIPT" || ci::skip "no $HCI_BUN_TEST_SCRIPT script"
    log::cmd bun run "$HCI_BUN_TEST_SCRIPT"
    return 0
  fi
  mkdir -p "${HCI_BUN_COVERAGE_PATH:-coverage}"
  log::cmd bun test --coverage --coverage-reporter=lcov --coverage-dir "${HCI_BUN_COVERAGE_PATH:-coverage}"
}
