ARG REGISTRY_HOST=registry.access.redhat.com
FROM ${REGISTRY_HOST}/ubi9/ubi-minimal:9.7-1776833838
LABEL maintainer="TOPCASE <tech@topcase.ru>" \
    name="hyperion/gradle.node" \
    description="Образ для сборки gradle с поддержкой nodejs"

ENV GRADLE_VERSION=9.2.1 \
    GRADLE_HOME=/opt/gradle \
    HOME=$GRADLE_HOME \
    PATH=$GRADLE_HOME/bin:${PATH}

# Gradle 9 требует Java 17+. which нужен gradle для поиска java.
RUN microdnf --nodocs install -y ca-certificates java-17-openjdk-headless unzip nodejs which \
    && microdnf clean all \
    && curl -fsSL -o gradle.zip https://services.gradle.org/distributions/gradle-$GRADLE_VERSION-bin.zip \
    && unzip gradle.zip \
    && rm gradle.zip \
    && mv gradle-$GRADLE_VERSION $GRADLE_HOME \
    && chgrp -R 0 $GRADLE_HOME \
    && chmod -R g=u $GRADLE_HOME
