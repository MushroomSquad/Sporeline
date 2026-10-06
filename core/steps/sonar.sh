# shellcheck shell=bash
# SonarQube. A runtime may provide:
#   rt::sonar_params  — prints extra -Dkey=value lines (one per line);
#   rt::sonar ARGS... — runs the analysis with its own tool (mvn sonar:sonar, gradle sonar, ...).
# Otherwise the sonar-scanner CLI is used.

step::sonar() {
  [[ -n "${HCI_SONAR_HOST_URL:-}" ]] || log::die "Не задан HCI_SONAR_HOST_URL (SONAR_HOST)"
  [[ -n "${HCI_SONAR_TOKEN:-}" ]] || log::die "Не задан HCI_SONAR_TOKEN (SONAR_KEY)"
  local key params=() extra=() line
  key="${HCI_SONAR_PROJECT_KEY:-$(naming::sonar_key)}"
  params=(
    "-Dsonar.host.url=$HCI_SONAR_HOST_URL"
    "-Dsonar.projectKey=$key"
    "-Dsonar.projectName=${HCI_SONAR_PROJECT_NAME:-${HCI_PROJECT_PATH:-$key}}"
    "-Dsonar.projectVersion=$(naming::version)"
    "-Dsonar.qualitygate.wait=${HCI_SONAR_QUALITYGATE_WAIT:-true}"
    "-Dsonar.scm.revision=${HCI_SHA:-}"
  )
  [[ -n "${HCI_SONAR_EXCLUSIONS:-}" ]] && params+=("-Dsonar.exclusions=$HCI_SONAR_EXCLUSIONS")
  if declare -F rt::sonar_params >/dev/null; then
    while IFS= read -r line; do [[ -n "$line" ]] && params+=("$line"); done < <(rt::sonar_params)
  fi
  ci::words extra "${HCI_SONAR_ARGS:-}"
  params+=("${extra[@]+"${extra[@]}"}")

  export SONAR_TOKEN="$HCI_SONAR_TOKEN"
  export SONAR_USER_HOME="${SONAR_USER_HOME:-$HCI_CACHE_DIR/sonar}"
  tls::bundle >/dev/null
  if tls::has_custom && ci::has keytool; then
    tls::java_truststore
    export SONAR_SCANNER_OPTS="${SONAR_SCANNER_OPTS:-} $HCI_JAVA_TLS_OPTS"
  fi

  if declare -F rt::sonar >/dev/null; then
    rt::sonar "${params[@]}"
  else
    ci::require sonar-scanner
    log::cmd sonar-scanner "${params[@]}"
  fi
}
