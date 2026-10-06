ARG REGISTRY_HOST=registry.access.redhat.com
FROM ${REGISTRY_HOST}/ubi8/dotnet-60:6.0-56
LABEL maintainer="TOPCASE <tech@topcase.ru>" \
    name="hyperion/dotnet-60-nodejs-16" \
    description="Образ для сборки net 6.0 с поддержкой nodejs 16"

USER 0

RUN yum -y module reset nodejs && \
    yum -y module enable nodejs:16 && \
    yum -y --setopt=tsflags=nodocs --setopt=install_weak_deps=False update nodejs npm && \
    yum clean all -y && \
    rm -rf /var/cache/yum/*

USER 1001
