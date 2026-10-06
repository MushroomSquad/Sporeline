# shellcheck shell=bash
# Хуки проекта.
#
# Файлы:   <HCI_HOOKS_DIR>/<step>.pre.sh и <step>.post.sh (":" в имени шага заменяется на "-")
# Inline:  HCI_<STEP>_PRE / HCI_<STEP>_POST (в .ci.yaml: build: { pre: "...", post: "..." })
# Хуки выполняются в том же shell, что и шаг, и могут менять переменные окружения шага.

hooks::_var() {
  local step="$1" phase="$2" name
  name="HCI_${step^^}_${phase^^}"
  printf '%s' "${name//[:-]/_}"
}

hooks::run() {
  local step="$1" phase="$2" file var
  file="${HCI_HOOKS_DIR:-.ci/hooks}/${step//:/-}.${phase}.sh"
  if [[ -f "$file" ]]; then
    log::section_start "hook_${step}_${phase}" "Хук $file"
    # shellcheck source=/dev/null
    source "$file"
    log::section_end "hook_${step}_${phase}"
  fi
  var="$(hooks::_var "$step" "$phase")"
  if [[ -n "${!var:-}" ]]; then
    log::section_start "hook_${step}_${phase}_inline" "Хук $var"
    eval "${!var}"
    log::section_end "hook_${step}_${phase}_inline"
  fi
}
