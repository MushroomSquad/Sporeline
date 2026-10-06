# shellcheck shell=bash
# Helm chart: lint + kubeconform; publishing to Nexus (helm-hosted) or an OCI registry.

helm::chart() {
  ci::yaml_to_json "$HCI_HELM_CHART_DIR/Chart.yaml" | jq -r ".$1 // empty"
}

step::helm_lint() {
  ci::require helm kubeconform
  [[ -f "$HCI_HELM_CHART_DIR/Chart.yaml" ]] || ci::skip "Chart.yaml не найден в $HCI_HELM_CHART_DIR"
  local values=() v vargs=() kargs=()
  ci::split values "${HCI_HELM_VALUES:-values.yaml}"
  for v in "${values[@]}"; do vargs+=(-f "$v"); done
  log::cmd helm dependency build "$HCI_HELM_CHART_DIR" >/dev/null 2>&1 || true
  log::cmd helm lint --strict "$HCI_HELM_CHART_DIR" "${vargs[@]}"
  ci::words kargs "${HCI_HELM_KUBECONFORM_ARGS:-}"
  helm template "$HCI_HELM_CHART_DIR" "${vargs[@]}" | log::cmd kubeconform "${kargs[@]+"${kargs[@]}"}" -
}

step::helm_publish() {
  ci::require helm
  naming::is_release || ci::is_true "${HCI_PUBLISH_SNAPSHOTS:-false}" || ci::skip "публикация чарта только по тегу"
  local name version pkg
  name="$(helm::chart name)"
  version="$(naming::version)"
  log::cmd helm package "$HCI_HELM_CHART_DIR" --version "$version" --app-version "$version" -d "$HCI_TMP"
  pkg="$HCI_TMP/$name-$version.tgz"

  if [[ "${HCI_HELM_PUBLISH_MODE:-nexus}" == "oci" ]]; then
    local host
    host="$(registry::host OCI_PUSH)"
    registry::oci_login OCI_PUSH
    retry log::cmd helm push "$pkg" "oci://$host/${HCI_IMAGES_FOLDER}/charts" --registry-config "$REGISTRY_AUTH_FILE"
    manifest::add helm "$name" "$version" "oci://$host/${HCI_IMAGES_FOLDER}/charts"
  else
    local url tls=()
    url="$(registry::url HELM push)"
    tls::curl_args tls
    retry curl -sS --fail "${tls[@]+"${tls[@]}"}" -K - --upload-file "$pkg" "$url/" < <(registry::curl_auth HELM)
    manifest::add helm "$name" "$version" "$url"
  fi
}
