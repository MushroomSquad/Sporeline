# shellcheck shell=bash
rt::build() {
  bun::install
  if ci::is_true "${HCI_NODE_SKIP_BUILD:-false}"; then
    log::info "Build skipped"
    return 0
  fi
  if bun::has_script build; then
    log::cmd bun run build
  elif [[ -n "${HCI_BUN_BUILD_ENTRYPOINT:-}" ]]; then
    [[ -f "$HCI_BUN_BUILD_ENTRYPOINT" ]] || log::die "Entrypoint '$HCI_BUN_BUILD_ENTRYPOINT' not found"
    mkdir -p "${HCI_IMAGE_CONTEXT:-build}"
    log::cmd bun build "$HCI_BUN_BUILD_ENTRYPOINT" --outdir "${HCI_IMAGE_CONTEXT:-build}"
  else
    log::die "No build script in package.json and HCI_BUN_BUILD_ENTRYPOINT is not set"
  fi
  if [[ "$HCI_SERVICE_TYPE" == "image" ]]; then
    [[ -d "${HCI_IMAGE_CONTEXT:-build}" ]] || log::die "Image context directory '${HCI_IMAGE_CONTEXT}' is empty or missing"
  fi
}
