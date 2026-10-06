# shellcheck shell=bash
dotnet::csproj() {
  if [[ -n "${HCI_DOTNET_CSPROJ:-}" ]]; then
    printf '%s' "$HCI_DOTNET_CSPROJ"
    return 0
  fi
  ci::first_file '*.csproj' '**/*.csproj' || return 1
}

dotnet::package_id() {
  local csproj="$1" id
  id="$(grep -oP '(?<=<PackageId>)[^<]+' "$csproj" | head -1 || true)"
  [[ -n "$id" ]] || id="$(basename "${csproj%.csproj}")"
  printf '%s' "$id"
}

dotnet::nuget_config() {
  local file="$HCI_TMP/nuget.config" url
  url="$(registry::url NUGET pull)/index.json"
  cat > "$file" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="hci" value="$(ci::xml_escape "$url")" />
  </packageSources>
  <packageSourceCredentials>
    <hci>
      <add key="Username" value="$(ci::xml_escape "$(registry::user NUGET)")" />
      <add key="ClearTextPassword" value="$(ci::xml_escape "$(registry::password NUGET)")" />
    </hci>
  </packageSourceCredentials>
</configuration>
EOF
  printf '%s' "$file"
}

rt::setup() {
  ci::require dotnet
  tls::bundle >/dev/null
  export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=true DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
  export NUGET_PACKAGES="${NUGET_PACKAGES:-$HCI_CACHE_DIR/nuget}"
  export HCI_DOTNET_NUGET_CONFIG
  HCI_DOTNET_NUGET_CONFIG="$(dotnet::nuget_config)"
  HCI_DOTNET_CSPROJ="$(dotnet::csproj)" || log::die "No .csproj found (HCI_DOTNET_CSPROJ)"
  export HCI_DOTNET_CSPROJ
  if [[ -z "${HCI_DOTNET_TEST_CSPROJ:-}" ]]; then
    HCI_DOTNET_TEST_CSPROJ="$(ci::first_file '*.Tests.csproj' '**/*.Tests.csproj' || true)"
    export HCI_DOTNET_TEST_CSPROJ
  fi
  export HCI_DOTNET_PACKAGE_ID
  HCI_DOTNET_PACKAGE_ID="$(dotnet::package_id "$HCI_DOTNET_CSPROJ")"
}

rt::sonar() {
  ci::require dotnet
  log::cmd dotnet sonarscanner begin "$@"
  log::cmd dotnet build --configuration "${HCI_DOTNET_CONFIG:-Release}" "$HCI_DOTNET_CSPROJ"
  log::cmd dotnet sonarscanner end
}

rt::svace_build_cmd() {
  printf 'dotnet build --configuration %q %q' "${HCI_DOTNET_CONFIG:-Release}" "$HCI_DOTNET_CSPROJ"
}

rt::detect_tools() { printf 'sdk=%s\npackage=%s\n' "$(dotnet --version 2>/dev/null || true)" "${HCI_DOTNET_PACKAGE_ID:-}"; }
