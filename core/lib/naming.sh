# shellcheck shell=bash
# Имена и версии артефактов.

naming::is_release() {
  [[ -n "${HCI_TAG:-}" ]] || ci::is_true "${HCI_RELEASE:-false}"
}

# Версия релиза: HCI_VERSION, иначе тег. Для не-релизных сборок — 0.0.0-<ветка>.<sha>.
naming::version() {
  local v="${HCI_VERSION:-}"
  if [[ -z "$v" && -n "${HCI_TAG:-}" ]]; then
    v="$HCI_TAG"
    ci::is_true "${HCI_VERSION_STRIP_V:-false}" && v="${v#v}"
  fi
  if [[ -z "$v" ]]; then
    local branch
    branch="$(ci::slug "${HCI_BRANCH:-${HCI_REF:-snapshot}}")"
    v="0.0.0-${branch:-snapshot}.${HCI_SHORT_SHA:-local}"
  fi
  printf '%s' "$v"
}

# Репозиторий образа без хоста: group/project или <namespace>/<code_hash>.
naming::image_repo() {
  if [[ -n "${HCI_IMAGE_NAME:-}" ]]; then
    printf '%s' "${HCI_IMAGE_NAME,,}"
  elif [[ -n "${HCI_CODE_HASH:-}" ]]; then
    printf '%s/%s' "${HCI_PROJECT_NAMESPACE,,}" "${HCI_CODE_HASH,,}"
  else
    printf '%s' "${HCI_PROJECT_PATH,,}"
  fi
}

# Основной тег образа.
naming::image_tag() {
  local core
  if naming::is_release; then
    core="$(naming::version)"
  else
    core="$(ci::slug "${HCI_BRANCH:-${HCI_REF:-dev}}")-${HCI_SHORT_SHA:-local}"
  fi
  local prefix="${HCI_IMAGE_TAG_PREFIX:-}"
  [[ -z "$prefix" && -n "${HCI_CEKIT_OVERRIDE:-}" ]] && prefix="${HCI_CEKIT_OVERRIDE}-"
  printf '%s%s%s' "$prefix" "$core" "${HCI_IMAGE_TAG_SUFFIX:-}"
}

naming::sonar_key() {
  if [[ -n "${HCI_SONAR_PROJECT_KEY:-}" ]]; then
    printf '%s' "$HCI_SONAR_PROJECT_KEY"
  else
    local repo
    repo="$(naming::image_repo)"
    printf '%s' "${repo//\//-}"
  fi
}
