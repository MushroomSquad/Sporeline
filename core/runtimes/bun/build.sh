# shellcheck shell=bash
rt::build() {
  bun::install
  if ci::is_true "${HCI_NODE_SKIP_BUILD:-false}"; then
    log::info "Сборка пропущена"
    return 0
  fi
  if bun::has_script build; then
    log::cmd bun run build
  elif [[ -n "${HCI_BUN_BUILD_ENTRYPOINT:-}" ]]; then
    [[ -f "$HCI_BUN_BUILD_ENTRYPOINT" ]] || log::die "Точка входа '$HCI_BUN_BUILD_ENTRYPOINT' не найдена"
    mkdir -p "${HCI_IMAGE_CONTEXT:-build}"
    log::cmd bun build "$HCI_BUN_BUILD_ENTRYPOINT" --outdir "${HCI_IMAGE_CONTEXT:-build}"
  else
    log::die "Нет скрипта build в package.json и не задан HCI_BUN_BUILD_ENTRYPOINT"
  fi
  if [[ "$HCI_SERVICE_TYPE" == "image" ]]; then
    [[ -d "${HCI_IMAGE_CONTEXT:-build}" ]] || log::die "Каталог контекста образа '${HCI_IMAGE_CONTEXT}' пуст или отсутствует"
  fi
}
