# shellcheck shell=bash
# Подпись и аттестация образов cosign.

sign::enabled() {
  if [[ -n "${HCI_COSIGN_KEY:-}" ]]; then
    return 0
  fi
  if ci::is_true "${HCI_SIGN_REQUIRED:-false}"; then
    log::die "Подпись обязательна (HCI_SIGN_REQUIRED=true), но HCI_COSIGN_KEY не задан"
  fi
  log::warn "HCI_COSIGN_KEY не задан, образ не подписывается"
  return 1
}

sign::_args() {
  local -n _sargs="$1"
  _sargs=(--key "$HCI_COSIGN_KEY" --yes)
  if ! ci::is_true "${HCI_COSIGN_TLOG:-false}"; then
    # Пустой signing config отключает transparency log и Fulcio (закрытый контур).
    local cfg="$HCI_TMP/cosign-signing-config.json"
    printf '{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json"}' > "$cfg"
    _sargs+=(--signing-config "$cfg")
  fi
  local extra=()
  ci::words extra "${HCI_COSIGN_ARGS:-}"
  _sargs+=("${extra[@]+"${extra[@]}"}")
  [[ -n "${HCI_COSIGN_PASSWORD:-}" ]] && export COSIGN_PASSWORD="$HCI_COSIGN_PASSWORD"
  if [[ -f "${REGISTRY_AUTH_FILE:-}" && -z "${DOCKER_CONFIG:-}" ]]; then
    export DOCKER_CONFIG="$HCI_TMP/docker"
    mkdir -p "$DOCKER_CONFIG"
    cp "$REGISTRY_AUTH_FILE" "$DOCKER_CONFIG/config.json"
  fi
  return 0
}

# sign::image REF@DIGEST [SBOM]
sign::image() {
  local ref="$1" sbom="${2:-}" args=()
  ci::require cosign
  sign::_args args
  if [[ -n "$sbom" && -f "$sbom" ]]; then
    retry log::cmd cosign attest "${args[@]}" --type cyclonedx --predicate "$sbom" "$ref"
  fi
  retry log::cmd cosign sign "${args[@]}" "$ref"
}
