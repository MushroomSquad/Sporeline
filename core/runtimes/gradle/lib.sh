# shellcheck shell=bash
# Gradle: repository init scripts (credentials via getenv), jacoco, publishing.

GRADLE=()

gradle::bin() {
  case "${HCI_GRADLE_WRAPPER:-auto}" in
    true) printf './gradlew' ;;
    false) printf 'gradle' ;;
    *) if [[ -x ./gradlew ]]; then printf './gradlew'; else printf 'gradle'; fi ;;
  esac
}

gradle::init_repo() {
  local file="$HCI_TMP/init.repo.gradle"
  cat > "$file" <<'EOF'
allprojects {
  repositories {
    maven {
      url = uri(System.getenv("HCI_MAVEN_PULL_URL") ?: "")
      allowInsecureProtocol = "http".equalsIgnoreCase(System.getenv("HCI_REGISTRY_SCHEME") ?: "https")
      credentials {
        username = System.getenv("HCI_MAVEN_USER") ?: ""
        password = System.getenv("HCI_MAVEN_PASSWORD") ?: ""
      }
    }
  }
  buildscript {
    repositories {
      maven {
        url = uri(System.getenv("HCI_MAVEN_PULL_URL") ?: "")
        allowInsecureProtocol = "http".equalsIgnoreCase(System.getenv("HCI_REGISTRY_SCHEME") ?: "https")
        credentials {
          username = System.getenv("HCI_MAVEN_USER") ?: ""
          password = System.getenv("HCI_MAVEN_PASSWORD") ?: ""
        }
      }
    }
  }
}
settingsEvaluated { settings ->
  settings.pluginManagement {
    repositories {
      maven {
        url = uri(System.getenv("HCI_MAVEN_PULL_URL") ?: "")
        allowInsecureProtocol = "http".equalsIgnoreCase(System.getenv("HCI_REGISTRY_SCHEME") ?: "https")
        credentials {
          username = System.getenv("HCI_MAVEN_USER") ?: ""
          password = System.getenv("HCI_MAVEN_PASSWORD") ?: ""
        }
      }
    }
  }
}
gradle.projectsEvaluated {
  def autoGroup = System.getenv("HCI_GRADLE_GROUP") ?: ""
  rootProject.allprojects { p ->
    def current = p.group?.toString()
    if ((!current || current == "unspecified") && autoGroup) {
      p.group = autoGroup
    }
  }
  rootProject.tasks.register("hciCoordinates") {
    doLast {
      rootProject.allprojects.each { p ->
        println("${p.group}:${p.name}:${p.version}")
      }
    }
  }
}
EOF
  printf '%s' "$file"
}

rt::setup() {
  local bin extra=()
  bin="$(gradle::bin)"
  [[ "$bin" == ./gradlew ]] || ci::require gradle
  tls::bundle >/dev/null
  tls::java_truststore
  export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HCI_CACHE_DIR/gradle}"
  export GRADLE_OPTS="${GRADLE_OPTS:-} -Dorg.gradle.daemon=false -Djava.awt.headless=true ${HCI_JAVA_TLS_OPTS:-}"
  mkdir -p "$GRADLE_USER_HOME"
  if registry::has MAVEN; then
    HCI_MAVEN_PULL_URL="$(registry::url MAVEN pull)/"
    HCI_MAVEN_USER="$(registry::user MAVEN)"
    HCI_MAVEN_PASSWORD="$(registry::password MAVEN)"
    export HCI_MAVEN_PULL_URL HCI_MAVEN_USER HCI_MAVEN_PASSWORD
  fi
  if [[ -z "${HCI_GRADLE_GROUP:-}" && -n "${HCI_PROJECT_PATH:-}" ]]; then
    HCI_GRADLE_GROUP="com.$(ci::slug "${HCI_PROJECT_PATH//\//.}")"
    HCI_GRADLE_GROUP="${HCI_GRADLE_GROUP//-/.}"
    export HCI_GRADLE_GROUP
  fi
  GRADLE=("$bin" --no-daemon --init-script "$(gradle::init_repo)" --build-cache)
  ci::words extra "${HCI_GRADLE_ARGS:-}"
  GRADLE+=("${extra[@]+"${extra[@]}"}")
}

gradle::run() { log::cmd "${GRADLE[@]}" "$@"; }

rt::sonar_params() {
  local cov
  cov="$(ci::glob_join '**/build/reports/jacoco/test/jacocoTestReport.xml')"
  [[ -n "$cov" ]] && printf '%s\n' "-Dsonar.coverage.jacoco.xmlReportPaths=$cov"
  printf '%s\n' "-Dsonar.sourceEncoding=UTF-8"
}

rt::svace_build_cmd() {
  printf '%q ' "${GRADLE[@]}" clean assemble --no-build-cache
}

rt::detect_tools() {
  printf 'build_tool=%s\n' "$(gradle::bin)"
}
