#!/usr/bin/env bats

load helper

setup() {
  hci_setup_workdir
  hci_source_libs
}
teardown() { hci_teardown_workdir; }

@test "ci::split делит по запятым и строкам" {
  ci::split arr $'a, b\nc,,  d '
  [ "${#arr[@]}" -eq 4 ]
  [ "${arr[3]}" = "d" ]
}

@test "ci::slug" {
  [ "$(ci::slug 'Feature/ABC_12--x')" = "feature-abc-12-x" ]
}

@test "ci::expand подставляет переменные" {
  FOO=bar
  [ "$(ci::expand 'x/${FOO}:"q"')" = 'x/bar:"q"' ]
}

@test "naming: версия из тега и snapshot-версия" {
  HCI_TAG=v1.2.3
  [ "$(naming::version)" = "v1.2.3" ]
  HCI_VERSION_STRIP_V=true
  [ "$(naming::version)" = "1.2.3" ]
  HCI_TAG="" HCI_BRANCH="feature/X" HCI_SHORT_SHA=abcdef12
  [ "$(naming::version)" = "0.0.0-feature-x.abcdef12" ]
  [ "$(naming::image_tag)" = "feature-x-abcdef12" ]
}

@test "naming: имя образа с CODE_HASH и явное имя" {
  HCI_PROJECT_PATH="Group/Sub/App" HCI_PROJECT_NAMESPACE=Group
  [ "$(naming::image_repo)" = "group/sub/app" ]
  HCI_CODE_HASH=ABC
  [ "$(naming::image_repo)" = "group/abc" ]
  HCI_IMAGE_NAME=custom/name
  [ "$(naming::image_repo)" = "custom/name" ]
  [ "$(naming::sonar_key)" = "custom-name" ]
}

@test "registry::url берёт общий хост и путь репозитория типа" {
  HCI_REGISTRY_SCHEME=https HCI_REGISTRY_HOST=nexus HCI_REGISTRY_MAVEN_PULL_REPO=repository/maven-public
  [ "$(registry::url maven pull)" = "https://nexus/repository/maven-public" ]
  HCI_REGISTRY_MAVEN_HOST=maven.example
  [ "$(registry::url maven pull)" = "https://maven.example/repository/maven-public" ]
}

@test "registry::url_with_auth экранирует учётные данные" {
  HCI_REGISTRY_SCHEME=https HCI_REGISTRY_HOST=nexus HCI_REGISTRY_PYPI_PULL_REPO=repository/pypi
  HCI_REGISTRY_USER='u@x' HCI_REGISTRY_PASSWORD='p:w/d'
  [ "$(registry::url_with_auth pypi pull)" = "https://u%40x:p%3Aw%2Fd@nexus/repository/pypi" ]
}

@test "manifest: purl для разных экосистем" {
  [ "$(manifest::purl maven 'com.acme:lib' 1.0)" = "pkg:maven/com.acme/lib@1.0" ]
  [ "$(manifest::purl npm '@acme/ui' 2.0.0)" = "pkg:npm/%40acme/ui@2.0.0" ]
  [ "$(manifest::purl pypi 'My_Pkg' 0.1)" = "pkg:pypi/my-pkg@0.1" ]
  [[ "$(manifest::purl oci 'group/app' 1.0 'sha256:ab' 'r.local')" == "pkg:oci/app@sha256%3Aab?repository_url=r.local%2Fgroup%2Fapp&tag=1.0" ]]
}

@test "manifest: добавление и проверка артефактов" {
  HCI_OUT_DIR="$WORKDIR/out" HCI_CI=gitlab HCI_SHA=abc HCI_REF=1.0
  manifest::add maven 'com.acme:lib' 1.0 https://nexus/repository/maven-releases files=lib.jar
  manifest::add oci group/app 1.0 r.local "digest=sha256:$(printf 'a%.0s' {1..64})" signed=true sbom=cyclonedx
  run manifest::validate
  [ "$status" -eq 0 ]
  [ "$(jq -r '.artifacts[1].signed | type' "$HCI_OUT_DIR/artifacts.json")" = "boolean" ]
  [ "$(jq -r '.artifacts | length' "$HCI_OUT_DIR/artifacts.json")" = "2" ]
}

@test "manifest: образ без digest не проходит проверку" {
  HCI_OUT_DIR="$WORKDIR/out"
  manifest::add oci group/app 1.0 r.local
  run manifest::validate
  [ "$status" -ne 0 ]
}

@test "manifest: неизвестный тип отклоняется" {
  HCI_OUT_DIR="$WORKDIR/out"
  run manifest::add rpm x 1 r
  [ "$status" -ne 0 ]
}
