# shellcheck shell=bash
# Kaspersky Container Security: scans an image's OCI layout with the KCS scanner.

step::kcs() {
  [[ "$HCI_SERVICE_TYPE" != "library" ]] || ci::skip "service_type=library"
  local oci="$HCI_WORKDIR_ABS/$HCI_OCI_DIR" entry="${HCI_KCS_ENTRYPOINT:-/entrypoint.sh}"
  [[ -d "$oci" ]] || log::die "No $HCI_OCI_DIR: step kcs must receive the image:build step's artifact"
  [[ -f "$entry" ]] || log::die "KCS scanner not found ($entry). Use the KCS scanner image."
  [[ -n "${HCI_KCS_URL:-}" && -n "${HCI_KCS_TOKEN:-}" ]] || log::die "HCI_KCS_URL / HCI_KCS_TOKEN are not set"
  export API_BASE_URL="$HCI_KCS_URL" API_TOKEN="$HCI_KCS_TOKEN" SKIP_API_SERVER_VALIDATION="${HCI_KCS_SKIP_API_VALIDATION:-true}"
  mkdir -p "$(dirname "$HCI_KCS_REPORT")"
  /bin/sh "$entry" --oci "$oci" \
    --original-target-name "$(naming::image_repo):$(naming::image_tag)" \
    --stdout --sbom > "$HCI_KCS_REPORT"
  log::ok "Report: $HCI_KCS_REPORT"
}
