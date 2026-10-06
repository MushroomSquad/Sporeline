# shellcheck shell=bash
rt::build() {
  if [[ -f package.json ]]; then
    # shellcheck source=/dev/null
    source "$HCI_HOME/runtimes/nodejs/lib.sh"
    node::setup
    node::install
    if node::has_script "${HCI_STATIC_BUILD_SCRIPT:-build}"; then
      node::run_script "${HCI_STATIC_BUILD_SCRIPT:-build}"
    fi
  fi
  [[ -d "${HCI_IMAGE_CONTEXT:-dist}" ]] || log::die "Нет каталога статики '${HCI_IMAGE_CONTEXT:-dist}'. Соберите фронтенд или задайте HCI_IMAGE_CONTEXT."
}
