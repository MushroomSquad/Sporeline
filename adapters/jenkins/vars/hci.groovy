#!/usr/bin/env groovy
/**
 * Запуск одного шага ядра Hyperion CI.
 *
 *   hci('build')
 *   hci(step: 'test', workdir: 'services/api', strict: false)
 *   hci(step: 'image:build', runtime: 'maven', runtimeVersion: '21')
 *
 * Код 78 (мягкий отказ при HCI_STRICT=false) → unstable, пайплайн не красный.
 */
def call(Object args) {
  Map opts
  if (args instanceof String || args instanceof GString) {
    opts = [step: args.toString()]
  } else if (args instanceof Map) {
    opts = args as Map
  } else {
    error('hci: ожидается строка шага или Map аргументов')
  }

  String step = opts.step as String
  if (!step?.trim()) {
    error('hci: укажите шаг, например hci("build") или hci(step: "test")')
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
        unstable("hci ${step}: мягкий отказ (код ${soft})")
        return
      }
      if (rc != 0) {
        error("hci ${step} завершился с кодом ${rc}")
      }
    }
  }
}
