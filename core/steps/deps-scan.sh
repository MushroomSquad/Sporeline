# shellcheck shell=bash
# Dependency analysis over sources and lock files (Trivy fs). Doesn't require a build.

step::deps_scan() {
  ci::require trivy
  local args=() skip_dirs=() d
  trivy::args args
  ci::split skip_dirs "${HCI_DEPS_SKIP_DIRS:-.git,.cache,${HCI_OCI_DIR},${HCI_OUT_DIR}}"
  for d in "${skip_dirs[@]}"; do args+=(--skip-dirs "$d"); done
  mkdir -p "$(dirname "$HCI_DEPS_REPORT")"
  log::cmd trivy fs "${args[@]}" --scanners vuln --format json --list-all-pkgs --output "$HCI_DEPS_REPORT" .
  trivy::finish "$HCI_DEPS_REPORT" "$HCI_DEPS_SBOM_FILE"
}
