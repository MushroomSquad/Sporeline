# shellcheck shell=bash
# Kaspersky Container Security: scans an image's OCI layout with the KCS scanner.

step::kcs() {
  [[ "$HCI_SERVICE_TYPE" != "library" ]] || ci::skip "service_type=library"
  local oci="$HCI_WORKDIR_ABS/$HCI_OCI_DIR" entry="${HCI_KCS_ENTRYPOINT:-/entrypoint.sh}"
  [[ -d "$oci" ]] || log::die "Нет $HCI_OCI_DIR: шаг kcs должен получать артефакт шага image:build"
  [[ -f "$entry" ]] || log::die "Сканер KCS не найден ($entry). Используйте образ сканера KCS."
  [[ -n "${HCI_KCS_URL:-}" && -n "${HCI_KCS_TOKEN:-}" ]] || log::die "Не заданы HCI_KCS_URL / HCI_KCS_TOKEN"
  export API_BASE_URL="$HCI_KCS_URL" API_TOKEN="$HCI_KCS_TOKEN" SKIP_API_SERVER_VALIDATION="${HCI_KCS_SKIP_API_VALIDATION:-true}"
  mkdir -p "$(dirname "$HCI_KCS_REPORT")"
  /bin/sh "$entry" --oci "$oci" \
    --original-target-name "$(naming::image_repo):$(naming::image_tag)" \
    --stdout --sbom > "$HCI_KCS_REPORT"
  log::ok "Отчёт: $HCI_KCS_REPORT"
}
