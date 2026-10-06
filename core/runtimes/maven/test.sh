# shellcheck shell=bash
# Тесты по классам из артефакта build; без него — с компиляцией.
rt::test() {
  local goals=() pre=()
  ci::words goals "$HCI_MAVEN_TEST_GOALS"
  if ! compgen -G 'target/classes' >/dev/null && ! compgen -G '*/target/classes' >/dev/null; then
    log::info "Нет скомпилированных классов (артефакт build не получен), компилируем"
    pre=(test-compile)
  fi
  mvn::run -Djacoco.append=true "${pre[@]+"${pre[@]}"}" "${goals[@]}"
}
