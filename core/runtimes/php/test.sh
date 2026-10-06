# shellcheck shell=bash
rt::test() {
  local dest="${HCI_PHP_VENDOR_DIR:-composer-build}"
  local autoload="$dest/vendor/autoload.php"
  [[ -f "$autoload" ]] || autoload=vendor/autoload.php
  [[ -f "$autoload" ]] || log::die "No vendor/autoload.php — run build first"
  local args=(--bootstrap "$autoload" --do-not-cache-result --log-junit phpunit-report.xml)
  if php -m | grep -qi xdebug; then
    args+=(--coverage-clover coverage.xml --coverage-filter "$dest/${HCI_PHP_COVERAGE_PATH:-src}")
  fi
  ci::require phpunit
  log::cmd phpunit "${args[@]}" "${HCI_PHP_TEST_PATH:-tests}"
}
