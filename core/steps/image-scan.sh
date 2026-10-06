# shellcheck shell=bash
# Trivy image analysis. One scan pass, SBOM derived from the report (reused when publishing).

step::image_scan() {
  ci::require trivy
  [[ "$HCI_SERVICE_TYPE" != "library" ]] || ci::skip "service_type=library"
  local oci="$HCI_WORKDIR_ABS/$HCI_OCI_DIR" args=()
  [[ -d "$oci" ]] || log::die "No $HCI_OCI_DIR: step image:scan must receive the image:build step's artifact"
  trivy::args args
  mkdir -p "$(dirname "$HCI_SCAN_REPORT")" "$(dirname "$HCI_SBOM_FILE")"
  log::cmd trivy image "${args[@]}" --input "$oci" --format json --list-all-pkgs --output "$HCI_SCAN_REPORT"
  trivy::finish "$HCI_SCAN_REPORT" "$HCI_SBOM_FILE"
}
