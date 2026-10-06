# shellcheck shell=bash
# SBOM образа (CycloneDX). Используется, если шаг image:scan выключен.

sbom::image() {
  local oci="$HCI_WORKDIR_ABS/$HCI_OCI_DIR" args=()
  ci::require trivy
  [[ -d "$oci" ]] || log::die "Нет $HCI_OCI_DIR для генерации SBOM"
  trivy::args args
  mkdir -p "$(dirname "$HCI_SBOM_FILE")"
  log::cmd trivy image "${args[@]}" --input "$oci" --format cyclonedx --output "$HCI_SBOM_FILE"
}

step::sbom() {
  [[ "$HCI_SERVICE_TYPE" != "library" ]] || ci::skip "service_type=library"
  sbom::image
}
