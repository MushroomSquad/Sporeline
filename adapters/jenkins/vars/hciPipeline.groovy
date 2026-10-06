#!/usr/bin/env groovy
/**
 * Тонкий declarative pipeline → ci <step>.
 * Логика (ветки, retry, manual) — в Jenkinsfile вокруг вызова или в when{} ниже по месту.
 * См. docs/pipeline.md
 *
 *   @Library('hyperion-ci') _
 *   hciPipeline(
 *     runtime: 'maven',
 *     runtimeVersion: '21',
 *     serviceType: 'image',
 *     buildImage: 'registry/ci-openjdk-21:…',
 *     toolsImage: 'registry/ci-tools:…',
 *   )
 */
def call(Map args = [:]) {
  String runtime = required(args, 'runtime')
  String buildImage = required(args, 'buildImage')
  String toolsImage = required(args, 'toolsImage')
  String runtimeVersion = args.runtimeVersion ?: ''
  String serviceType = args.serviceType ?: 'image'
  String profile = args.profile ?: ''
  String workdir = args.workdir ?: '.'
  String agentLabel = args.agentLabel ?: 'linux'
  boolean strict = args.containsKey('strict') ? args.strict as boolean : true
  boolean doTest = args.containsKey('test') ? args.test as boolean : true
  boolean doLint = args.containsKey('lint') ? args.lint as boolean : true
  boolean doDepsScan = args.containsKey('depsScan') ? args.depsScan as boolean : true
  boolean doImageBuild = args.containsKey('imageBuild') ? args.imageBuild as boolean : true
  boolean doImageScan = args.containsKey('imageScan') ? args.imageScan as boolean : true
  boolean doImagePublish = args.containsKey('imagePublish') ? args.imagePublish as boolean : true
  boolean doPublish = args.containsKey('publish') ? args.publish as boolean : true
  boolean doSonar = args.containsKey('sonar') ? args.sonar as boolean : false

  pipeline {
    agent none
    options {
      timestamps()
      disableConcurrentBuilds(abortPrevious: true)
      buildDiscarder(logRotator(numToKeepStr: '30'))
    }
    environment {
      HCI_RUNTIME = "${runtime}"
      HCI_RUNTIME_VERSION = "${runtimeVersion}"
      HCI_SERVICE_TYPE = "${serviceType}"
      HCI_PROFILE = "${profile}"
      HCI_STRICT = "${strict}"
      HCI_WORKDIR = "${workdir}"
    }
    stages {
      stage('build') {
        agent {
          docker {
            image buildImage
            label agentLabel
            reuseNode true
          }
        }
        steps {
          checkout scm
          script { hci(step: 'build', workdir: workdir) }
          stash name: 'hci-build', includes: "${workdir}/hci-artifacts/**,${workdir}/target/**,${workdir}/build/**,${workdir}/dist/**,${workdir}/.venv/**,${workdir}/app", allowEmpty: true
        }
      }

      stage('parallel-checks') {
        parallel {
          stage('lint') {
            when { expression { doLint } }
            agent {
              docker {
                image buildImage
                label agentLabel
              }
            }
            steps {
              checkout scm
              script { hci(step: 'lint', workdir: workdir) }
            }
          }
          stage('deps:scan') {
            when { expression { doDepsScan } }
            agent {
              docker {
                image toolsImage
                label agentLabel
              }
            }
            steps {
              checkout scm
              script { hci(step: 'deps:scan', workdir: workdir) }
            }
          }
          stage('test') {
            when { expression { doTest } }
            agent {
              docker {
                image buildImage
                label agentLabel
              }
            }
            steps {
              checkout scm
              unstash 'hci-build'
              script { hci(step: 'test', workdir: workdir) }
            }
          }
          stage('sonar') {
            when { expression { doSonar } }
            agent {
              docker {
                image buildImage
                label agentLabel
              }
            }
            steps {
              checkout scm
              unstash 'hci-build'
              script { hci(step: 'sonar', workdir: workdir) }
            }
          }
        }
      }

      stage('image:build') {
        when {
          allOf {
            expression { doImageBuild }
            expression { serviceType == 'image' }
          }
        }
        agent {
          docker {
            image toolsImage
            label agentLabel
            args '--privileged'
          }
        }
        steps {
          checkout scm
          unstash 'hci-build'
          script { hci(step: 'image:build', workdir: workdir) }
          stash name: 'hci-oci', includes: "${workdir}/oci-image/**", allowEmpty: false
        }
      }

      stage('image:scan') {
        when {
          allOf {
            expression { doImageScan }
            expression { serviceType == 'image' }
          }
        }
        agent {
          docker {
            image toolsImage
            label agentLabel
          }
        }
        steps {
          checkout scm
          unstash 'hci-oci'
          script { hci(step: 'image:scan', workdir: workdir) }
          stash name: 'hci-scan', includes: "${workdir}/hci-artifacts/**", allowEmpty: true
        }
      }

      stage('image:publish') {
        when {
          allOf {
            expression { doImagePublish }
            expression { serviceType == 'image' }
            buildingTag()
          }
        }
        agent {
          docker {
            image toolsImage
            label agentLabel
          }
        }
        steps {
          checkout scm
          unstash 'hci-oci'
          script {
            try {
              unstash 'hci-scan'
            } catch (Exception ignored) {
              echo 'hci-scan stash отсутствует, продолжаем без отчёта скана'
            }
            hci(step: 'image:publish', workdir: workdir)
          }
          archiveArtifacts artifacts: "${workdir}/hci-artifacts/**", allowEmptyArchive: true, fingerprint: true
        }
      }

      stage('publish') {
        when {
          allOf {
            expression { doPublish }
            expression { serviceType == 'library' }
            buildingTag()
          }
        }
        agent {
          docker {
            image buildImage
            label agentLabel
          }
        }
        steps {
          checkout scm
          unstash 'hci-build'
          script { hci(step: 'publish', workdir: workdir) }
          archiveArtifacts artifacts: "${workdir}/hci-artifacts/**", allowEmptyArchive: true, fingerprint: true
        }
      }
    }
  }
}

private String required(Map args, String key) {
  if (!args[key]) {
    error("hciPipeline: обязательный параметр ${key}")
  }
  return args[key] as String
}
