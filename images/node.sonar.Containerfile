ARG REGISTRY_HOST=registry.access.redhat.com
FROM ${REGISTRY_HOST}/ubi9/ubi-minimal:9.7-1776833838
LABEL maintainer="TOPCASE <tech@topcase.ru>" \
    name="hyperion/node.sonar" \
    description="Комбинированный образ sonar scanner и nodejs для анализа кода в Гиперионе"

ENV SONAR_SCANNER_VERSION=7.3.0.5189-linux-x64 \
    SONAR_SCANNER_HOME=/opt/sonar-scanner \
    HOME=/tmp \
    PATH=$SONAR_SCANNER_HOME/bin:${PATH}

RUN TMP_PKGS="unzip" \
    && microdnf --nodocs install -y $TMP_PKGS ca-certificates java-21-openjdk-headless nodejs \
    && curl -fsSL -o sonar-scanner.zip https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-$SONAR_SCANNER_VERSION.zip \
    && unzip sonar-scanner.zip \
    && rm sonar-scanner.zip \
    && mv sonar-scanner-${SONAR_SCANNER_VERSION} $SONAR_SCANNER_HOME \
    && chgrp -R 0 $SONAR_SCANNER_HOME \
    && chmod -R g=u $SONAR_SCANNER_HOME \
    && microdnf remove -y $TMP_PKGS \
    && microdnf clean all \
    && rm -rf /mnt/rootfs/var/cache/* /mnt/rootfs/var/log/dnf* /mnt/rootfs/var/log/yum.*

WORKDIR $SONAR_SCANNER_HOME

USER 1001
