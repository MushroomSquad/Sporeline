# shellcheck shell=bash
rt::publish() {
  naming::is_release || ci::skip "публикация nupkg только по тегу"
  local nupkg ver key url
  ver="$(naming::version)"
  nupkg="${HCI_DOTNET_PUBLISH_PATH:-publish}/${HCI_DOTNET_PACKAGE_ID}.${ver}.nupkg"
  [[ -f "$nupkg" ]] || nupkg="$(ci::first_file "${HCI_DOTNET_PUBLISH_PATH:-publish}"/*.nupkg || true)"
  [[ -f "$nupkg" ]] || log::die "Не найден nupkg в ${HCI_DOTNET_PUBLISH_PATH:-publish}"
  url="$(registry::url NUGET push)/"
  key="${HCI_REGISTRY_NUGET_API_KEY:-$(registry::password NUGET)}"
  retry log::cmd dotnet nuget push "$nupkg" -s "$url" -k "$key" --skip-duplicate
  manifest::add nuget "$HCI_DOTNET_PACKAGE_ID" "$ver" "$url"
}
