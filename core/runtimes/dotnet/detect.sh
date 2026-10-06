# shellcheck shell=bash
rt::detect() {
  find . -maxdepth 4 \( -name '*.csproj' -o -name '*.sln' \) -print -quit | grep -q .
}
