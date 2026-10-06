# shellcheck shell=bash
rt::detect() {
  [[ -f build.gradle || -f build.gradle.kts || -f settings.gradle || -f settings.gradle.kts ]]
}
