# shellcheck shell=bash
# Project hooks.
#
# Files:   <HCI_HOOKS_DIR>/<step>.pre.sh and <step>.post.sh (":" in the step name becomes "-")
# Inline:  HCI_<STEP>_PRE / HCI_<STEP>_POST (in .ci.yaml: build: { pre: "...", post: "..." })
# Hooks run in the same shell as the step and can change the step's environment variables.

hooks::_var() {
  local step="$1" phase="$2" name
  name="HCI_${step^^}_${phase^^}"
  printf '%s' "${name//[:-]/_}"
}

hooks::run() {
  local step="$1" phase="$2" file var
  file="${HCI_HOOKS_DIR:-.ci/hooks}/${step//:/-}.${phase}.sh"
  if [[ -f "$file" ]]; then
    log::section_start "hook_${step}_${phase}" "Hook $file"
    # shellcheck source=/dev/null
    source "$file"
    log::section_end "hook_${step}_${phase}"
  fi
  var="$(hooks::_var "$step" "$phase")"
  if [[ -n "${!var:-}" ]]; then
    log::section_start "hook_${step}_${phase}_inline" "Hook $var"
    eval "${!var}"
    log::section_end "hook_${step}_${phase}_inline"
  fi
}
