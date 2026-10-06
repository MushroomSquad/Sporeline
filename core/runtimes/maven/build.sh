# shellcheck shell=bash
rt::build() {
  mvn::apply_version
  mvn::run -DskipTests clean "${HCI_MAVEN_BUILD_PHASE:-package}"
}
