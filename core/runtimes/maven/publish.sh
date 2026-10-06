# shellcheck shell=bash
# Публикация библиотеки в Maven-репозиторий (releases по тегу, snapshots при HCI_PUBLISH_SNAPSHOTS=true).
rt::publish() {
  local kind=push url goals=() g a v p published=0
  if ! naming::is_release; then
    ci::is_true "${HCI_PUBLISH_SNAPSHOTS:-false}" || ci::skip "публикация библиотеки только по тегу (или HCI_PUBLISH_SNAPSHOTS=true)"
    kind=snapshot
  fi
  url="$(registry::url MAVEN "$kind")"
  mvn::apply_version
  ci::words goals "${HCI_MAVEN_PUBLISH_GOALS:-}"
  retry mvn::run -DskipTests "${goals[@]+"${goals[@]}"}" "${HCI_MAVEN_DEPLOY_PLUGIN}:deploy" \
    "-DaltDeploymentRepository=hci::$url"

  while IFS=: read -r g a v p; do
    [[ "$p" == pom ]] && continue
    manifest::add maven "$g:$a" "$v" "$url" "packaging=$p"
    published=$((published + 1))
  done < <(mvn::coordinates)
  if (( published == 0 )); then
    while IFS=: read -r g a v p; do manifest::add maven "$g:$a" "$v" "$url" "packaging=$p"; done < <(mvn::coordinates)
  fi
}
