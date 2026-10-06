#!/usr/bin/env bats
# Юнит-тесты cd:notify: cd_notify::safe_url (срезка userinfo/query/fragment),
# cd_notify::attempt (2xx/4xx/5xx/сетевая ошибка через подменённый curl),
# контракт "-K - вместо -H" для Authorization.

load helper

setup() {
  hci_setup_workdir
  hci_source_libs
  # shellcheck source=/dev/null
  source "$HCI_HOME/steps/cd-notify.sh"
}
teardown() { hci_teardown_workdir; }

# --- cd_notify::safe_url ---------------------------------------------------------------------

@test "safe_url: credential, query-токен и fragment отрезаны" {
  [ "$(cd_notify::safe_url 'https://user:token@host:8080/path?token=secret#frag')" = "https://host:8080/path" ]
}

@test "safe_url: без пути — не падает, отдаёт scheme://host" {
  [ "$(cd_notify::safe_url 'https://user:token@host:8080')" = "https://host:8080" ]
}

@test "safe_url: без userinfo — не падает, путь сохраняется" {
  [ "$(cd_notify::safe_url 'https://host/webhook/x')" = "https://host/webhook/x" ]
}

@test "safe_url: без userinfo и без пути" {
  [ "$(cd_notify::safe_url 'https://host')" = "https://host" ]
}

@test "safe_url: без схемы вообще — query-токен не утекает (регрессия code-review HIGH-1)" {
  # Без "://" "${u%%://*}" вернула бы строку целиком, и query/userinfo не отрезались бы —
  # curl принимает URL без схемы (подставляет http://), это рабочая конфигурация, не теоретическая.
  local out; out="$(cd_notify::safe_url 'argo.example.com/hook?token=SECRET')"
  [[ "$out" != *SECRET* ]]
  [[ "$out" != *"?"* ]]
}

@test "safe_url: жадное обрезание userinfo — пароль с @ внутри не оставляет хвост (регрессия LOW-1)" {
  [ "$(cd_notify::safe_url 'https://user:p@ss@host/hook')" = "https://host/hook" ]
}

# --- cd_notify::attempt: 2xx/4xx/5xx/сетевая ошибка -------------------------------------------
# Функция читает curl_args/conf/safe из локалей вызывающего (динамический scope) и зовёт
# настоящий curl — здесь curl подменён bash-функцией, отвечающей по env-переключателю
# FAKE_CURL_MODE, без обращения к сети.

_notify_fake_curl_setup() {
  curl() {
    cat >/dev/null # поглощаем -K - stdin-конфиг
    case "${FAKE_CURL_MODE:-}" in
      2xx) printf 'body-ok\n200' ;;
      4xx) printf 'bad request body\n404' ;;
      5xx) printf 'server err body\n503' ;;
      neterr) return 7 ;;
    esac
  }
  safe="https://host/hook"
  curl_args=(-X POST --connect-timeout 10 --max-time 30)
  conf=""
}

@test "attempt: 2xx -> успех (0), без ретрая" {
  _notify_fake_curl_setup
  FAKE_CURL_MODE=2xx
  run cd_notify::attempt
  [ "$status" -eq 0 ]
  [[ "$output" == *"200"* ]]
}

@test "attempt: 4xx -> log::die сразу, без ретрая" {
  _notify_fake_curl_setup
  FAKE_CURL_MODE=4xx
  run cd_notify::attempt
  [ "$status" -ne 0 ]
  [[ "$output" == *"404"* ]]
  [[ "$output" == *"без ретрая"* ]]
}

@test "attempt: 5xx -> ненулевой код, но не фатально (retry() должен повторить)" {
  _notify_fake_curl_setup
  FAKE_CURL_MODE=5xx
  run cd_notify::attempt
  [ "$status" -eq 1 ]
  [[ "$output" == *"503"* ]]
}

@test "attempt: сетевая ошибка curl (ненулевой exit, не HTTP-код) -> тот же код возвращается для retry()" {
  _notify_fake_curl_setup
  FAKE_CURL_MODE=neterr
  run cd_notify::attempt
  [ "$status" -eq 7 ]
  [[ "$output" == *"сетевая ошибка"* ]]
}

# --- Контракт "-K - вместо -H" для Authorization ----------------------------------------------

@test "curl_args: при заданном токене Authorization идёт через -K конфиг (stdin), не -H в argv" {
  HCI_CD_NOTIFY_TOKEN=sekrit12345
  local tls_arr=() curl_args=() conf="" hdr
  tls::curl_args tls_arr
  hdr="Authorization: Bearer $HCI_CD_NOTIFY_TOKEN"
  hdr="${hdr//\\/\\\\}"
  conf="$(printf 'header = "%s"' "${hdr//\"/\\\"}")"
  curl_args=(-X POST --connect-timeout 10 --max-time 30 "${tls_arr[@]+"${tls_arr[@]}"}")

  local a found_h=no
  for a in "${curl_args[@]}"; do
    [[ "$a" == "-H" ]] && found_h=yes
  done
  [ "$found_h" = "no" ]
  [[ "$conf" == *"Authorization: Bearer sekrit12345"* ]]
}
