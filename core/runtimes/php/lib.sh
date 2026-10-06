# shellcheck shell=bash
rt::setup() {
  ci::require php
  tls::bundle >/dev/null
  export COMPOSER_HOME="${COMPOSER_HOME:-$HCI_CACHE_DIR/composer}"
  mkdir -p "$COMPOSER_HOME"
  if ci::has composer && registry::has COMPOSER; then
    log::cmd composer config -g repo.packagist composer "$(registry::url COMPOSER pull)/"
    if [[ -n "$(registry::user COMPOSER)" ]]; then
      log::cmd composer config -g http-basic."$(registry::host COMPOSER)" "$(registry::user COMPOSER)" "$(registry::password COMPOSER)"
    fi
  fi
}

rt::sonar_params() {
  [[ -f coverage.xml ]] && printf '%s\n' "-Dsonar.php.coverage.reportPaths=coverage.xml"
  [[ -f phpunit-report.xml ]] && printf '%s\n' "-Dsonar.php.tests.reportPath=phpunit-report.xml"
}

rt::detect_tools() { printf 'php=%s\n' "$(php -r 'echo PHP_VERSION;' 2>/dev/null || true)"; }
