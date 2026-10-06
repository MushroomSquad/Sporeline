# shellcheck shell=bash
rt::test() {
  local init="$HCI_TMP/init.jacoco.gradle"
  cat > "$init" <<EOF
initscript {
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
allprojects { project ->
  project.plugins.withType(JavaPlugin) {
    project.apply plugin: "jacoco"
    project.jacoco { toolVersion = "${HCI_JACOCO_VERSION:-0.8.12}" }
    project.jacocoTestReport {
      reports { xml.required = true; html.required = true }
    }
    project.tasks.named("test") { finalizedBy project.tasks.jacocoTestReport }
  }
}
EOF
  gradle::run --init-script "$init" test jacocoTestReport
}
