[English](README.md) | [Русский](README.ru.md)

# Jenkins Adapter

Shared library: `hci('build')` / `hciPipeline(...)`. Logic lives in the **Jenkinsfile**
(Groovy `when`, `retry`, `input`).
See [docs/pipeline.md](../../docs/pipeline.md).

## A Single Step

```groovy
@Library('hyperion-ci') _

pipeline {
  agent { docker { image 'registry.example/ci-openjdk-21:…' } }
  stages {
    stage('build') { steps { script { hci('build') } } }
    stage('test')  { steps { script { hci(step: 'test', strict: false) } } }
  }
}
```

Code **78** → `unstable`.

## Full Pipeline (Thin Default)

```groovy
@Library('hyperion-ci') _

hciPipeline(
  runtime: 'maven',
  runtimeVersion: '21',
  serviceType: 'image',
  buildImage: 'registry.example/ci-openjdk-21:…',
  toolsImage: 'registry.example/ci-tools:…',
)
```

For your own branch/manual logic, write a declarative/scripted Jenkinsfile with
`hci(step: …)` directly.

## Granular Components

For a fully custom graph built from individual components, see
[Level 3](../../docs/pipeline.md#level-3-a-custom-graph-from-individual-components):

```groovy
@Library('hyperion-ci') _
pipeline {
  agent { docker { image 'registry.example/ci-openjdk-21:…' } }
  stages {
    stage('build') { steps { script { hci(step: 'build') } } }
    stage('test')  { steps { script { hci(step: 'test') } } }
  }
}
```
