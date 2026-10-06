#!/usr/bin/env bats

load helper

setup() { hci_setup_workdir; }
teardown() { hci_teardown_workdir; }

@test "неизвестная команда завершается ошибкой" {
  run "$HCI_TEST_BIN" frobnicate --runtime=none
  [ "$status" -ne 0 ]
  [[ "$output" == *"Неизвестная команда: frobnicate"* ]]
}

@test "пользовательская команда шага через HCI_<STEP>_CMD" {
  HCI_TEST_CMD='echo custom-test' run "$HCI_TEST_BIN" test --runtime=none
  [ "$status" -eq 0 ]
  [[ "$output" == *"custom-test"* ]]
}

@test "шаг можно отключить через HCI_<STEP>_ENABLED=false" {
  run "$HCI_TEST_BIN" image:build --runtime=none --image-build-enabled=false
  [ "$status" -eq 0 ]
  [[ "$output" == *"отключён"* ]]
}

@test "мягкий шаг в нестрогом режиме возвращает HCI_SOFT_EXIT_CODE" {
  run "$HCI_TEST_BIN" lint --runtime=none --lint-cmd=false --strict=false
  [ "$status" -eq 78 ]
}

@test "мягкий шаг в строгом режиме возвращает исходный код" {
  run "$HCI_TEST_BIN" lint --runtime=none --lint-cmd='exit 3' --strict=true
  [ "$status" -eq 3 ]
}

@test "строгость можно задать для отдельного шага" {
  run "$HCI_TEST_BIN" lint --runtime=none --lint-cmd=false --strict=true --lint-strict=false
  [ "$status" -eq 78 ]
}

@test "жёсткий шаг падает даже в нестрогом режиме" {
  run "$HCI_TEST_BIN" build --runtime=none --build-cmd=false --strict=false
  [ "$status" -eq 1 ]
}

@test "хуки pre/post из файлов и inline выполняются в окружении шага" {
  mkdir -p .ci/hooks
  echo 'export FROM_PRE=yes; echo pre-file' > .ci/hooks/build.pre.sh
  echo 'echo "post-file FROM_PRE=$FROM_PRE"' > .ci/hooks/build.post.sh
  HCI_BUILD_POST='echo post-inline' run "$HCI_TEST_BIN" build --runtime=none --build-cmd='echo body'
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre-file"*"body"*"post-file FROM_PRE=yes"*"post-inline"* ]]
}

@test "post-хук не выполняется при ошибке шага" {
  HCI_BUILD_POST='echo must-not-run' run "$HCI_TEST_BIN" build --runtime=none --build-cmd=false
  [ "$status" -ne 0 ]
  [[ "$output" != *"must-not-run"* ]]
}

@test "шаг, не поддерживаемый рантаймом, пропускается" {
  run "$HCI_TEST_BIN" lint --runtime=maven
  [ "$status" -eq 0 ]
  [[ "$output" == *"не поддерживает шаг lint"* ]]
}

@test "рабочий каталог задаётся через --workdir" {
  mkdir -p sub
  printf 'runtime: none\nbuild:\n  cmd: pwd\n' > sub/.ci.yaml
  run "$HCI_TEST_BIN" build --workdir=sub
  [ "$status" -eq 0 ]
  [[ "$output" == *"/sub"* ]]
}

@test "неверный service_type отклоняется" {
  run "$HCI_TEST_BIN" build --runtime=none --service-type=binary
  [ "$status" -ne 0 ]
  [[ "$output" == *"image или library"* ]]
}
