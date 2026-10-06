#!/usr/bin/env bats

load helper

setup() { hci_setup_workdir; }
teardown() { hci_teardown_workdir; }

@test "env важнее .ci.yaml, .ci.yaml важнее defaults рантайма" {
  printf 'runtime: maven\nservice_type: library\nruntime_version: "17"\n' > .ci.yaml
  HCI_SERVICE_TYPE=image run "$HCI_TEST_BIN" config
  [ "$status" -eq 0 ]
  [[ "$output" == *"HCI_SERVICE_TYPE=image"* ]]
  [[ "$output" == *"HCI_RUNTIME_VERSION=17"* ]]
  [[ "$output" == *"HCI_RUNTIME=maven"* ]]
}

@test "аргумент командной строки важнее env" {
  HCI_STRICT=true run "$HCI_TEST_BIN" config --strict=false --runtime=none
  [ "$status" -eq 0 ]
  [[ "$output" == *"HCI_STRICT=false"* ]]
}

@test "defaults рантайма важнее defaults ядра" {
  run "$HCI_TEST_BIN" config --runtime=maven
  [[ "$output" == *"HCI_IMAGE_WORKDIR=/deployments"* ]]
}

@test "списки, словари labels и секция env из .ci.yaml" {
  cat > .ci.yaml <<'EOF'
runtime: none
image:
  platforms: [linux/amd64, linux/arm64]
  labels: {team: core}
env:
  MY_FLAG: "42"
build:
  cmd: echo "flag=$MY_FLAG platforms=$(echo $HCI_IMAGE_PLATFORMS) labels=$HCI_IMAGE_LABELS"
EOF
  run "$HCI_TEST_BIN" build
  [ "$status" -eq 0 ]
  [[ "$output" == *"flag=42 platforms=linux/amd64 linux/arm64 labels=team=core"* ]]
}

@test "старые переменные платформы используются как источники" {
  NEXUS_HOST=nexus.example REGISTRY_INT_HOST=push.example HTTP_SCHEMA=http run "$HCI_TEST_BIN" config --runtime=none
  [[ "$output" == *"HCI_REGISTRY_OCI_HOST=nexus.example"* ]]
  [[ "$output" == *"HCI_REGISTRY_OCI_PUSH_HOST=push.example"* ]]
  [[ "$output" == *"HCI_REGISTRY_SCHEME=http"* ]]
}

@test "секреты скрыты в выводе config" {
  NEXUS_PASSWORD=very-secret-value run "$HCI_TEST_BIN" config --runtime=none
  [[ "$output" != *"very-secret-value"* ]]
  [[ "$output" == *"HCI_REGISTRY_PASSWORD=***"* ]]
}

@test "автоопределение рантайма по файлам проекта" {
  touch pyproject.toml
  run "$HCI_TEST_BIN" detect
  [[ "$output" == *"runtime=python"* ]]
  rm pyproject.toml
  echo '{}' > package.json
  touch bun.lock
  run "$HCI_TEST_BIN" detect
  [[ "$output" == *"runtime=bun"* ]]
  rm bun.lock
  run "$HCI_TEST_BIN" detect
  [[ "$output" == *"runtime=nodejs"* ]]
}

@test "неизвестный рантайм — понятная ошибка" {
  run "$HCI_TEST_BIN" config --runtime=cobol
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown runtime 'cobol'"* ]]
}
