# shellcheck shell=bash
rt::publish() {
  naming::is_release || ci::is_true "${HCI_PUBLISH_SNAPSHOTS:-false}" || ci::skip "library publish only runs on a tag"
  local kind=push url init
  naming::is_release || kind=snapshot
  url="$(registry::url MAVEN "$kind")"
  export HCI_MAVEN_PUSH_URL="$url"
  init="$HCI_TMP/init.publish.gradle"
  cat > "$init" <<'EOF'
allprojects {
  afterEvaluate { project ->
    if (!project.plugins.hasPlugin("maven-publish") && !project.tasks.findByName("publish")) {
      return
    }
    project.pluginManager.apply("maven-publish")
    project.publishing {
      repositories {
        maven {
          name = "hci"
          url = uri(System.getenv("HCI_MAVEN_PUSH_URL"))
          allowInsecureProtocol = "http".equalsIgnoreCase(System.getenv("HCI_REGISTRY_SCHEME") ?: "https")
          credentials {
            username = System.getenv("HCI_MAVEN_USER") ?: ""
            password = System.getenv("HCI_MAVEN_PASSWORD") ?: ""
          }
        }
      }
      if (publications.isEmpty() && project.components.findByName("java")) {
        publications {
          hci(MavenPublication) {
            from project.components.java
            groupId = project.group.toString()
            artifactId = project.name
            version = project.version.toString()
          }
        }
      }
    }
  }
}
EOF
  retry gradle::run --init-script "$init" publish
  local line
  while IFS= read -r line; do
    [[ "$line" == *:*:* ]] || continue
    manifest::add maven "${line%:*}" "${line##*:}" "$url"
  done < <(gradle::run -q hciCoordinates 2>/dev/null || true)
}
