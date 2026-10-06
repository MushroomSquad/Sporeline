# shellcheck shell=bash
rt::build() {
  local cfg="${HCI_DOTNET_CONFIG:-Release}" rid="${HCI_DOTNET_RUNTIME:-linux-x64}" out="${HCI_DOTNET_PUBLISH_PATH:-publish}"
  log::cmd dotnet restore -r "$rid" --configfile "$HCI_DOTNET_NUGET_CONFIG" "$HCI_DOTNET_CSPROJ"
  if [[ -n "${HCI_DOTNET_TEST_CSPROJ:-}" && -f "$HCI_DOTNET_TEST_CSPROJ" ]]; then
    log::cmd dotnet restore -r "$rid" --configfile "$HCI_DOTNET_NUGET_CONFIG" "$HCI_DOTNET_TEST_CSPROJ"
    log::cmd dotnet build --no-restore -c "$cfg" -r "$rid" --configfile "$HCI_DOTNET_NUGET_CONFIG" "$HCI_DOTNET_TEST_CSPROJ"
  fi
  if [[ "$HCI_SERVICE_TYPE" == "library" ]]; then
    log::cmd dotnet pack --no-restore -c "$cfg" -o "$out" -p:PackageVersion="$(naming::version)" "$HCI_DOTNET_CSPROJ"
  else
    log::cmd dotnet publish --no-restore -c "$cfg" -r "$rid" --no-self-contained -o "$out" --configfile "$HCI_DOTNET_NUGET_CONFIG" "$HCI_DOTNET_CSPROJ"
    : "${HCI_IMAGE_CMD:=dotnet ${HCI_DOTNET_PACKAGE_ID}.dll}"
    export HCI_IMAGE_CMD
  fi
}
