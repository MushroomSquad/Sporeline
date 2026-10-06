#!/usr/bin/env bats

load helper

setup() { hci_setup_workdir; }
teardown() { hci_teardown_workdir; }

@test "maven определяется по pom.xml" {
  echo '<project/>' > pom.xml
  run "$HCI_TEST_BIN" detect
  [ "$status" -eq 0 ]
  [[ "$output" == *"runtime=maven"* ]]
}

@test "профиль quarkus меняет контекст образа" {
  echo '<project/>' > pom.xml
  run "$HCI_TEST_BIN" config --runtime=maven --profile=quarkus
  [ "$status" -eq 0 ]
  [[ "$output" == *"HCI_IMAGE_CONTEXT=target/quarkus-app"* ]]
  [[ "$output" == *"HCI_IMAGE_WORKDIR=/deployments"* ]]
}

@test "lint у maven пропускается" {
  echo '<project/>' > pom.xml
  run "$HCI_TEST_BIN" lint --runtime=maven
  [ "$status" -eq 0 ]
  [[ "$output" == *"не поддерживает шаг lint"* ]]
}

@test "пароль реестра не печатается при настройке maven" {
  echo '<project/>' > pom.xml
  NEXUS_HOST=nexus.example NEXUS_USER=alice NEXUS_PASSWORD=super-secret-pw \
    run "$HCI_TEST_BIN" run --runtime=maven -- true
  [ "$status" -eq 0 ]
  [[ "$output" != *"super-secret-pw"* ]]
}
