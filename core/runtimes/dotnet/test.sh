# shellcheck shell=bash
rt::test() {
  [[ -n "${HCI_DOTNET_TEST_CSPROJ:-}" && -f "$HCI_DOTNET_TEST_CSPROJ" ]] || ci::skip "нет тестового проекта (*.Tests.csproj)"
  log::cmd dotnet add "$HCI_DOTNET_TEST_CSPROJ" package coverlet.collector --version "${HCI_DOTNET_COVERLET_VERSION:-6.0.4}"
  log::cmd dotnet test --no-restore --configuration "${HCI_DOTNET_CONFIG:-Release}" \
    --collect:"XPlat Code Coverage" --results-directory TestResults \
    --logger "trx;LogFileName=test-result.xml" "$HCI_DOTNET_TEST_CSPROJ"
}
