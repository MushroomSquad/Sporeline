# shellcheck shell=bash
# Tests run against classes from the build artifact; without it, compiles first.
rt::test() {
  local goals=() pre=()
  ci::words goals "$HCI_MAVEN_TEST_GOALS"
  if ! compgen -G 'target/classes' >/dev/null && ! compgen -G '*/target/classes' >/dev/null; then
    log::info "No compiled classes (the build artifact wasn't received), compiling"
    pre=(test-compile)
  fi
  mvn::run -Djacoco.append=true "${pre[@]+"${pre[@]}"}" "${goals[@]}"
}
