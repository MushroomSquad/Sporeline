#!/usr/bin/env groovy
/**
 * Runs a single Hyperion CI core step.
 *
 *   hci('build')
 *   hci(step: 'test', workdir: 'services/api', strict: false)
 *   hci(step: 'image:build', runtime: 'maven', runtimeVersion: '21')
 *
 * Code 78 (soft failure when HCI_STRICT=false) → unstable, the pipeline isn't red.
 */
def call(Object args) {
  Map opts
  if (args instanceof String || args instanceof GString) {
    opts = [step: args.toString()]
  } else if (args instanceof Map) {
    opts = args as Map
  } else {
    error('hci: expected a step string or a Map of arguments')
  }

  String step = opts.step as String
  if (!step?.trim()) {
    error('hci: specify a step, e.g. hci("build") or hci(step: "test")')
  }

  String workdir = (opts.workdir ?: env.HCI_WORKDIR ?: '.') as String
  String ciBin = (opts.ciBin ?: env.HCI_CI_BIN ?: 'ci') as String
  String strict = opts.containsKey('strict') ? opts.strict.toString() : (env.HCI_STRICT ?: 'true')

  List<String> envList = [
    "HCI_CI_BIN=${ciBin}",
    "HCI_WORKDIR=${workdir}",
    "HCI_STRICT=${strict}",
  ]
  [
    runtime: 'HCI_RUNTIME',
    runtimeVersion: 'HCI_RUNTIME_VERSION',
    serviceType: 'HCI_SERVICE_TYPE',
    profile: 'HCI_PROFILE',
  ].each { key, name ->
    if (opts[key]) {
      envList << "${name}=${opts[key]}"
    }
  }

  withEnv(envList) {
    dir(workdir) {
      int rc = sh(script: "${ciBin} ${step}", returnStatus: true)
      int soft = (env.HCI_SOFT_EXIT_CODE ?: '78') as int
      if (rc == soft) {
        unstable("hci ${step}: soft failure (code ${soft})")
        return
      }
      if (rc != 0) {
        error("hci ${step} exited with code ${rc}")
      }
    }
  }
}
