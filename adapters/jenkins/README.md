# Jenkins — адаптер

Shared library: `hci('build')` / `hciPipeline(...)`. Логика — в **Jenkinsfile** (Groovy `when`, `retry`, `input`).
См. [docs/pipeline.md](../../docs/pipeline.md).

## Один шаг

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

Код **78** → `unstable`.

## Полный пайплайн (тонкий дефолт)

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

Своя логика веток/manual — пишите declarative/scripted Jenkinsfile с `hci(step: …)` напрямую.

## Гранулярные компоненты

Для полностью кастомного графа из отдельных компонентов см. [Уровень 3](../../docs/pipeline.md#уровень-3-свой-граф-из-отдельных-компонентов):

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
