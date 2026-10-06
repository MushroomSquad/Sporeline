# shellcheck shell=bash
rt::build() {
  local tasks=()
  ci::words tasks "${HCI_GRADLE_BUILD_TASKS:-clean assemble}"
  gradle::run "${tasks[@]}"
}
