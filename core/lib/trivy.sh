# shellcheck shell=bash
# Shared Trivy functions: one scan pass -> JSON report, SBOM and threshold check from it.

trivy::args() {
  local -n _targs="$1"
  _targs=(--timeout "${HCI_TRIVY_TIMEOUT:-10m}" --no-progress)
  if [[ -n "${HCI_TRIVY_SERVER:-}" ]]; then
    _targs+=(--server "$HCI_TRIVY_SERVER")
  else
    # Standalone mode (no server set): Trivy pulls its vulnerability DB from ghcr.io/aquasecurity
    # by default. In an air-gapped environment, point *_DB_REPOSITORY at an internal OCI mirror of that DB.
    [[ -n "${HCI_TRIVY_DB_REPOSITORY:-}" ]] && _targs+=(--db-repository "$HCI_TRIVY_DB_REPOSITORY")
    [[ -n "${HCI_TRIVY_JAVA_DB_REPOSITORY:-}" ]] && _targs+=(--java-db-repository "$HCI_TRIVY_JAVA_DB_REPOSITORY")
  fi
  _targs+=(--ignorefile "$(trivy::ignorefile)")
  # Credentials for private images and registries.
  export TRIVY_USERNAME="${TRIVY_USERNAME:-$(registry::user OCI)}"
  export TRIVY_PASSWORD="${TRIVY_PASSWORD:-$(registry::password OCI)}"
  if registry::is_insecure; then
    export TRIVY_INSECURE=true
  fi
}

trivy::ignorefile() {
  local file="$HCI_TMP/trivyignore" ids=() id
  if [[ ! -f "$file" ]]; then
    : > "$file"
    [[ -f .trivyignore ]] && cat .trivyignore >> "$file"
    ci::split ids "${HCI_SCAN_IGNORE_CVES:-}"
    for id in "${ids[@]+"${ids[@]}"}"; do printf '%s\n' "$id" >> "$file"; done
  fi
  printf '%s' "$file"
}

# trivy::finish REPORT SBOM — CycloneDX SBOM from the report, and a severity-threshold check.
trivy::finish() {
  local report="$1" sbom="$2"
  log::cmd trivy convert --format cyclonedx --output "$sbom" "$report"
  log::cmd trivy convert --format table --severity "${HCI_SCAN_FAIL_SEVERITY:-CRITICAL}" --exit-code 1 "$report"
}
