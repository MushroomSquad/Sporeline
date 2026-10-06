#!/usr/bin/env python3
"""Unit-тесты минимального rules() из tools/generate.py и гранулярных templates/<category>-<step>.yml."""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import generate as g  # noqa: E402

TEMPLATES = ROOT / "templates"
# Имена бандлов — только чтение списка рантаймов из meta.yaml (load_runtimes), без обращения
# к логике генерации самих гранулярных файлов, чтобы не проверять generate.py сам на себе.
BUNDLE_NAMES = set(g.load_runtimes()) | {"image", "helm", "analyze"}
GRANULAR_FILES = sorted(p for p in TEMPLATES.glob("*.yml") if p.stem not in BUNDLE_NAMES)

INPUT_REF_RE = re.compile(r"\$\[\[ inputs\.(\w+) \]\]")
CORE_INPUTS = {
    "job_prefix", "workdir", "strict", "runner_tag", "registry_host",
    "images_folder", "image_flavor", "core_version", "ci_bin",
}
CONTROL_INPUT_NAMES = {"needs", "rules", "when", "retry"}


def _load(path: Path) -> tuple[str, list]:
    """Сырой текст + 2 YAML-документа файла (spec, job), прочитанные напрямую с диска —
    без вызова internal-функций generate.py, чтобы баг в логике генератора не мог
    одновременно испортить и файл, и тест, который его проверяет."""
    text = path.read_text()
    return text, list(yaml.safe_load_all(text))


def _job_body(path: Path) -> dict:
    _, docs = _load(path)
    _, job_doc = docs
    return next(iter(job_doc.values()))


class RulesTest(unittest.TestCase):
    def test_enabled(self):
        r = g.rules()
        self.assertEqual(len(r), 1)
        self.assertEqual(r[0]["if"], '$HCI_JOB_ENABLED == "true"')

    def test_image_tag(self):
        r = g.rules(image_only=True, tag_only=True)
        self.assertIn("$CI_COMMIT_TAG", r[0]["if"])
        self.assertIn('$HCI_SERVICE_TYPE == "image"', r[0]["if"])

    def test_library_tag(self):
        r = g.rules(library_only=True, tag_only=True)
        self.assertIn('$HCI_SERVICE_TYPE == "library"', r[0]["if"])

    def test_no_gates(self):
        r = g.rules(enabled=False)
        self.assertEqual(r, [{"when": "on_success"}])

    def test_no_control_inputs(self):
        self.assertFalse(hasattr(g, "control_inputs"))
        base = g.base_inputs(["build"])
        self.assertNotIn("branches", base)
        self.assertNotIn("publish_mode", base)
        self.assertNotIn("job_retry", base)

        # Гранулярные файлы не должны реинтродьюсить "конструкторский" паттерн
        # (needs/rules/when/retry как управляющие inputs) — docs/DECISIONS.md §6.1.
        for path in GRANULAR_FILES:
            with self.subTest(file=path.name):
                _, (spec_doc, _) = _load(path)
                declared = set(spec_doc["spec"]["inputs"])
                self.assertFalse(declared & CONTROL_INPUT_NAMES, f"{path.name}: {declared & CONTROL_INPUT_NAMES}")


class GranularFilesTest(unittest.TestCase):
    """Структурные и ценностные проверки всех 67 templates/<category>-<step>.yml."""

    def test_discovery_sane(self):
        # Если глоб внезапно ничего не найдёт, остальные тесты в этом классе молча
        # пройдут на пустом списке — явно проверяем, что список не пуст.
        self.assertGreater(len(GRANULAR_FILES), 0)

    def test_count_exactly_67(self):
        self.assertEqual(len(GRANULAR_FILES), 67, sorted(p.name for p in GRANULAR_FILES))

    def test_count_breakdown_by_category(self):
        runtime_names = set(g.load_runtimes())
        runtime_files = [p for p in GRANULAR_FILES if p.stem.split("-", 1)[0] in runtime_names]
        image_files = [p for p in GRANULAR_FILES if p.name.startswith("image-image-")]
        helm_files = [p for p in GRANULAR_FILES if p.name.startswith("helm-helm-")]
        self.assertEqual(len(runtime_files), 62)
        self.assertEqual(len(image_files), 3)
        self.assertEqual(len(helm_files), 2)
        self.assertEqual(len(runtime_files) + len(image_files) + len(helm_files), len(GRANULAR_FILES))

        expected_per_runtime = {
            "bun": 7, "dotnet": 6, "go": 6, "gradle": 6, "maven": 6,
            "nodejs": 7, "php": 5, "python": 7, "rust": 7, "static": 5,
        }
        actual_per_runtime: dict[str, int] = {}
        for p in runtime_files:
            rt = p.stem.split("-", 1)[0]
            actual_per_runtime[rt] = actual_per_runtime.get(rt, 0) + 1
        self.assertEqual(actual_per_runtime, expected_per_runtime)

    def test_one_job_no_extends(self):
        for path in GRANULAR_FILES:
            with self.subTest(file=path.name):
                _, docs = _load(path)
                self.assertEqual(len(docs), 2, f"{path.name}: ожидалось 2 YAML-документа")
                spec_doc, job_doc = docs
                self.assertIn("spec", spec_doc)
                self.assertEqual(len(job_doc), 1, f"{path.name}: ожидался один джоб, получено {list(job_doc)}")
                self.assertNotIn("extends", next(iter(job_doc.values())))

    def test_no_hci_job_enabled(self):
        for path in GRANULAR_FILES:
            with self.subTest(file=path.name):
                self.assertNotIn("HCI_JOB_ENABLED", path.read_text())

    def test_needs_optional(self):
        for path in GRANULAR_FILES:
            with self.subTest(file=path.name):
                for entry in _job_body(path).get("needs") or []:
                    self.assertIs(entry.get("optional"), True, f"{path.name}: {entry}")

    def test_tags_universal(self):
        for path in GRANULAR_FILES:
            with self.subTest(file=path.name):
                self.assertEqual(_job_body(path).get("tags"), ["$[[ inputs.runner_tag ]]"])

    def test_cache_policy(self):
        for path in GRANULAR_FILES:
            with self.subTest(file=path.name):
                cache = _job_body(path).get("cache")
                if cache is None:
                    continue
                # "-build.yml" == реальный шаг build (cache override pull-push в runtime_component);
                # "-image-build.yml" — шаг image:build, он тоже матчит суффикс "-build.yml", но
                # cache у него не переопределяется и остаётся pull, как у test/lint/publish/image:*.
                is_build_step = path.name.endswith("-build.yml") and not path.name.endswith("-image-build.yml")
                expected = "pull-push" if is_build_step else "pull"
                self.assertEqual(cache.get("policy"), expected, f"{path.name}: cache.policy")

    def test_interruptible(self):
        for path in GRANULAR_FILES:
            with self.subTest(file=path.name):
                job = _job_body(path)
                self.assertIn("interruptible", job, f"{path.name}: нет ключа interruptible")
                self.assertEqual(job["interruptible"], not path.name.endswith("-publish.yml"))

    def test_helm_tools_image(self):
        for name in ("helm-helm-lint.yml", "helm-helm-publish.yml"):
            with self.subTest(file=name):
                self.assertEqual(_job_body(TEMPLATES / name).get("image"), "$[[ inputs.tools_image ]]")

    def test_inputs_match_usage_exactly(self):
        """Регрессия на раунд-4 shallow-merge баги: spec.inputs должен ровно совпадать с
        множеством $[[ inputs.X ]], реально встречающихся в сыром тексте файла — независимый
        повторный скан файла с диска, не через internal-состояние generate.py."""
        for path in GRANULAR_FILES:
            with self.subTest(file=path.name):
                text, (spec_doc, _) = _load(path)
                used = set(INPUT_REF_RE.findall(text))
                declared = set(spec_doc["spec"]["inputs"])
                self.assertEqual(declared, used, f"{path.name}: diff={declared ^ used}")

    def test_core_inputs_superset(self):
        for path in GRANULAR_FILES:
            with self.subTest(file=path.name):
                _, (spec_doc, _) = _load(path)
                declared = set(spec_doc["spec"]["inputs"])
                self.assertTrue(CORE_INPUTS <= declared, f"{path.name}: missing {CORE_INPUTS - declared}")

    def test_rules_narrowed(self):
        """rules() в standalone-рендере без enabled/image_only/library_only, tag_only сохранён
        (явно проверяем фактическое значение rules на диске, не только отсутствие HCI_JOB_ENABLED —
        иначе image_only/library_only-утечка остаётся незамеченной, т.к. не содержит этой строки)."""
        for path in GRANULAR_FILES:
            with self.subTest(file=path.name):
                r = _job_body(path).get("rules")
                is_real_build = path.name.endswith("-build.yml") and not path.name.endswith("-image-build.yml")
                if is_real_build:
                    self.assertIsNone(r, f"{path.name}: build не должен иметь rules (как в бандле)")
                elif path.name.endswith("-publish.yml"):
                    self.assertEqual(r, [{"if": "$CI_COMMIT_TAG"}])
                else:
                    self.assertEqual(r, [{"when": "on_success"}])


class StandaloneJobsUnitTest(unittest.TestCase):
    """Прямой юнит-тест на standalone_jobs() — merge-формулу нельзя проверить по факту на
    реальных 67 файлах, т.к. среди них нет job-level variable, конфликтующей с base (кроме
    HCI_JOB_ENABLED, который всегда выпиливается) — без этого теста направление merge
    (job побеждает base по-ключно) может развернуться незаметно при добавлении нового шага."""

    def test_variables_merge_job_wins_per_key(self):
        base_job = {"tags": ["t"], "interruptible": True, "variables": {"A": "base", "B": "base"}}
        job = {
            "extends": ".base",
            "variables": {"A": "job", "HCI_JOB_ENABLED": "$[[ inputs.toggle ]]"},
            "script": ["s"],
        }
        jobs = {g.job_name("build"): job}
        out = g.standalone_jobs("c", ("build",), base_job, jobs, {"job_prefix": {}})
        self.assertEqual(len(out), 1)
        _, _, body = out[0]
        merged = next(iter(body.values()))
        self.assertEqual(merged["variables"], {"A": "job", "B": "base"})
        self.assertNotIn("HCI_JOB_ENABLED", merged["variables"])
        self.assertNotIn("extends", merged)


if __name__ == "__main__":
    unittest.main()
