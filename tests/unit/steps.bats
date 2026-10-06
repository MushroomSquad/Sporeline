#!/usr/bin/env bats
# Shared steps with buildah/skopeo/trivy/cosign stubs: verify the commands they build.

load helper

setup() {
  hci_clean_env
  hci_setup_workdir
  STUBS="$BATS_TEST_TMPDIR/stubs"
  export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
  mkdir -p "$STUBS"
  local t
  for t in buildah skopeo trivy cosign; do
    cat > "$STUBS/$t" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$STUB_LOG"
tool="$(basename "$0")"
prev=""
for a in "$@"; do
  case "$prev" in
    --iidfile) echo "sha256:$(printf '%064d' 1)" > "$a" ;;
    --digestfile) echo "sha256:$(printf 'a%.0s' {1..64})" > "$a" ;;
    --output) echo '{}' > "$a" ;;
  esac
  prev="$a"
done
if [[ "$tool" == buildah && "$1" == from ]]; then echo ctr; fi
if [[ "$tool" == buildah && "$1" == push ]]; then mkdir -p "${@: -1}"; mkdir -p "${3#oci:}"; fi
exit 0
EOF
    chmod +x "$STUBS/$t"
  done
  export PATH="$STUBS:$PATH"
  export HCI_REGISTRY_HOST=nexus.local HCI_REGISTRY_USER=u HCI_REGISTRY_PASSWORD=secretpw
}

teardown() { hci_teardown_workdir; }

@test "image:build base: копирует контекст с исключениями и задаёт config" {
  mkdir -p build/lib
  touch build/app.jar build/app-sources.jar build/lib/a.jar
  run "$HCI_TEST_BIN" image:build --runtime=static --image-build-mode=base --runtime-image=base:1 \
    --image-context='build/*.jar' --image-context-exclude='*-sources.jar' \
    --image-cmd='java -jar app.jar' --image-ports=8080
  [ "$status" -eq 0 ]
  grep -q 'buildah from --pull --platform linux/amd64 base:1' "$STUB_LOG"
  grep -q 'buildah copy --chown 1001:0 ctr build/app.jar /opt/app-root/src/app.jar' "$STUB_LOG"
  ! grep -q 'app-sources.jar' "$STUB_LOG"
  grep -q -- '--port 8080' "$STUB_LOG"
  grep -q -- '--cmd java -jar app.jar' "$STUB_LOG"
  grep -q 'buildah push' "$STUB_LOG"
}

@test "image:build: Containerfile включает режим dockerfile с кэшем слоёв" {
  echo 'FROM scratch' > Containerfile
  run "$HCI_TEST_BIN" image:build --runtime=static
  [ "$status" -eq 0 ]
  grep -q 'buildah bud --layers' "$STUB_LOG"
  grep -q -- '--cache-from nexus.local/group/sub/project/buildcache' "$STUB_LOG"
}

@test "image:build: несколько платформ собираются в manifest list" {
  echo 'FROM scratch' > Containerfile
  run "$HCI_TEST_BIN" image:build --runtime=static --image-platforms=linux/amd64,linux/arm64
  [ "$status" -eq 0 ]
  grep -q 'buildah manifest create' "$STUB_LOG"
  grep -q 'buildah manifest push --all' "$STUB_LOG"
}

@test "image:build: пустой контекст — понятная ошибка" {
  run "$HCI_TEST_BIN" image:build --runtime=static --image-build-mode=base --runtime-image=base:1 --image-context='nothing/*'
  [ "$status" -ne 0 ]
  [[ "$output" == *"ничего не найдено"* ]]
}

@test "image:scan: один проход trivy, SBOM и порог из отчёта" {
  mkdir -p oci-image
  run "$HCI_TEST_BIN" image:scan --runtime=static --scan-ignore-cves=CVE-1,CVE-2
  [ "$status" -eq 0 ]
  [ "$(grep -c '^trivy image' "$STUB_LOG")" -eq 1 ]
  grep -q 'trivy convert --format cyclonedx' "$STUB_LOG"
  grep -q 'trivy convert --format table --severity CRITICAL --exit-code 1' "$STUB_LOG"
}

@test "image:scan: дефолт — server-режим, --db-repository не передаётся даже если задан" {
  mkdir -p oci-image
  run "$HCI_TEST_BIN" image:scan --runtime=static --trivy-db-repository=internal.example/mirror/trivy-db
  [ "$status" -eq 0 ]
  grep -q -- '--server http://trivy:8080' "$STUB_LOG"
  ! grep -q -- '--db-repository' "$STUB_LOG"
}

@test "image:scan: standalone-режим (сервер пуст) — DB-зеркало уходит как --db-repository/--java-db-repository" {
  mkdir -p oci-image
  run "$HCI_TEST_BIN" image:scan --runtime=static --trivy-server= \
    --trivy-db-repository=internal.example/mirror/trivy-db \
    --trivy-java-db-repository=internal.example/mirror/trivy-java-db
  [ "$status" -eq 0 ]
  ! grep -q -- '--server' "$STUB_LOG"
  grep -q -- '--db-repository internal.example/mirror/trivy-db' "$STUB_LOG"
  grep -q -- '--java-db-repository internal.example/mirror/trivy-java-db' "$STUB_LOG"
}

@test "image:scan: standalone-режим без явного зеркала — ни один DB-флаг не передаётся (дефолт Trivy на ghcr.io)" {
  mkdir -p oci-image
  run "$HCI_TEST_BIN" image:scan --runtime=static --trivy-server=
  [ "$status" -eq 0 ]
  ! grep -q -- '--server' "$STUB_LOG"
  ! grep -q -- '--db-repository' "$STUB_LOG"
  ! grep -q -- '--java-db-repository' "$STUB_LOG"
}

@test "image:publish: digest, подпись, аттестация и манифест" {
  mkdir -p oci-image hci-artifacts
  echo '{}' > hci-artifacts/sbom.cdx.json
  run "$HCI_TEST_BIN" image:publish --runtime=static --cosign-key=k.pem --image-extra-tags=stable
  [ "$status" -eq 0 ]
  grep -q 'skopeo copy --all' "$STUB_LOG"
  grep -q 'cosign attest .*--type cyclonedx' "$STUB_LOG"
  grep -q 'cosign sign' "$STUB_LOG"
  ! grep -q 'secretpw' <<< "$output"
  run jq -r '.artifacts[0] | "\(.type) \(.signed) \(.digest)"' hci-artifacts/artifacts.json
  [[ "$output" == "oci true sha256:"* ]]
  run "$HCI_TEST_BIN" manifest:validate --runtime=static
  [ "$status" -eq 0 ]
}

@test "image:publish: без ключа подпись пропускается, с HCI_SIGN_REQUIRED — ошибка" {
  mkdir -p oci-image
  run "$HCI_TEST_BIN" image:publish --runtime=static
  [ "$status" -eq 0 ]
  ! grep -q 'cosign sign' "$STUB_LOG"
  run "$HCI_TEST_BIN" image:publish --runtime=static --sign-required=true
  [ "$status" -ne 0 ]
}

@test "library: шаги образа пропускаются" {
  run "$HCI_TEST_BIN" image:build --runtime=static --service-type=library
  [ "$status" -eq 0 ]
  [[ "$output" == *"service_type=library"* ]]
}
