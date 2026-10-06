# shellcheck shell=bash
# Maven: settings.xml с зеркалом Nexus, truststore, общая команда MVN.

MVN=()

mvn::settings() {
  local file="$HCI_TMP/settings.xml" user pass mirror=""
  user="$(ci::xml_escape "$(registry::user MAVEN)")"
  pass="$(ci::xml_escape "$(registry::password MAVEN)")"
  if registry::has MAVEN; then
    mirror="<mirror><id>hci</id><url>$(ci::xml_escape "$(registry::url MAVEN pull)")/</url><mirrorOf>external:*</mirrorOf></mirror>"
  else
    log::warn "Реестр Maven не задан: зависимости берутся из репозиториев проекта"
  fi
  cat > "$file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <pluginGroups>
    <pluginGroup>org.sonarsource.scanner.maven</pluginGroup>
  </pluginGroups>
  <servers>
    <server><id>hci</id><username>${user}</username><password>${pass}</password></server>
  </servers>
  <mirrors>${mirror}</mirrors>
</settings>
EOF
  printf '%s' "$file"
}

mvn::bin() {
  case "${HCI_MAVEN_WRAPPER:-auto}" in
    true) printf './mvnw' ;;
    false) printf 'mvn' ;;
    *) if [[ -x ./mvnw ]]; then printf './mvnw'; else printf 'mvn'; fi ;;
  esac
}

rt::setup() {
  local bin settings extra=()
  bin="$(mvn::bin)"
  [[ "$bin" == ./mvnw ]] || ci::require mvn
  tls::bundle >/dev/null
  tls::java_truststore
  export MAVEN_OPTS="${MAVEN_OPTS:-} ${HCI_JAVA_TLS_OPTS:-}"
  settings="$(mvn::settings)"
  MVN=("$bin" -s "$settings" --batch-mode --errors --no-transfer-progress
    "-Dmaven.repo.local=$HCI_CACHE_DIR/m2")
  [[ -n "${HCI_MAVEN_THREADS:-}" ]] && MVN+=(-T "$HCI_MAVEN_THREADS")
  ci::words extra "${HCI_MAVEN_ARGS:-}"
  MVN+=("${extra[@]+"${extra[@]}"}")
}

mvn::run() { log::cmd "${MVN[@]}" "$@"; }

# Значение выражения Maven корневого модуля (project.version и т.п.).
mvn::eval() {
  "${MVN[@]}" -q -N -DforceStdout "-Dexpression=$1" \
    org.apache.maven.plugins:maven-help-plugin:3.5.1:evaluate 2>/dev/null
}

# Координаты всех модулей реактора: groupId:artifactId:version:packaging.
mvn::coordinates() {
  "${MVN[@]}" -q -Dexec.executable=echo \
    # Maven подставляет ${project.*} сам; shell не должен раскрывать.
    # shellcheck disable=SC2016,SC2288
    '-Dexec.args=${project.groupId}:${project.artifactId}:${project.version}:${project.packaging}' \
    org.codehaus.mojo:exec-maven-plugin:3.5.0:exec 2>/dev/null | grep -E '^[^:[:space:]]+:[^:]+:[^:]+:[^:]+$'
}

mvn::set_version() {
  local version="$1"
  mvn::run org.codehaus.mojo:versions-maven-plugin:2.18.0:set "-DnewVersion=$version" \
    -DgenerateBackupPoms=false -DprocessAllModules=true
}

# Версия сборки: тег релиза или SNAPSHOT текущей версии pom.xml.
mvn::apply_version() {
  ci::is_true "${HCI_MAVEN_SET_VERSION:-true}" || return 0
  local current
  if naming::is_release; then
    mvn::set_version "$(naming::version)"
  else
    current="$(mvn::eval project.version)"
    [[ -n "$current" ]] || log::die "Не удалось определить project.version"
    [[ "$current" == *-SNAPSHOT ]] || mvn::set_version "$current-SNAPSHOT"
  fi
}

rt::sonar_params() {
  local cov
  cov="$(ci::glob_join "${HCI_MAVEN_COVERAGE_FILES:-**/target/site/jacoco/jacoco.xml}")"
  if [[ -n "$cov" ]]; then
    printf '%s\n' "-Dsonar.coverage.jacoco.xmlReportPaths=$cov"
  else
    log::warn "Отчёт покрытия JaCoCo не найден (${HCI_MAVEN_COVERAGE_FILES})"
  fi
  printf '%s\n' "-Dsonar.sourceEncoding=UTF-8"
}

rt::sonar() {
  mvn::run "$@" sonar:sonar
}

rt::svace_build_cmd() {
  printf '%q ' "${MVN[@]}" clean install -DskipTests
}

rt::detect_tools() {
  printf 'build_tool=%s\n' "$(mvn::bin)"
}
