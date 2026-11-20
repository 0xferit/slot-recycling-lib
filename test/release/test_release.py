from http import HTTPStatus
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile


RELEASE = Path(__file__).resolve().parents[2] / "scripts" / "release.py"
LIBRARY = "src/SlotRecyclingLib.sol"


class ReleaseTest(unittest.TestCase):
    def setUp(self):
        fixture = tempfile.TemporaryDirectory()
        self.addCleanup(fixture.cleanup)
        self.repo = Path(fixture.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.write(LIBRARY, 'library SlotRecyclingLib {\n    string internal constant VERSION = "1.1.0";\n}\n')
        for path in ("LICENSE", "README.md", "SECURITY.md", "STABILITY.md"):
            self.write(path, f"fixture {path}\n")
        self.write("CHANGELOG.md", "## 1.1.0\n\nPrevious release\n")
        self.commit("chore(release): 1.1.0")
        self.git("update-ref", "refs/tags/v1.1.0", self.git("rev-parse", "HEAD"))

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True).strip()

    def write(self, path, text):
        file = self.repo / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def commit(self, *messages):
        self.git("add", ".")
        parent = subprocess.run(["git", "rev-parse", "--verify", "HEAD"], cwd=self.repo, text=True,
                                capture_output=True, check=False)
        parents = ("-p", parent.stdout.strip()) if parent.returncode == 0 else ()
        subject_and_body = tuple(arg for msg in messages for arg in ("-m", msg))
        commit = self.git("commit-tree", self.git("write-tree"), *parents, *subject_and_body)
        self.git("update-ref", "HEAD", commit)
        return commit

    def release(self, *args, check=True):
        return subprocess.run(
            [sys.executable, str(RELEASE), *args], cwd=self.repo, text=True,
            capture_output=True, check=check,
        )

    def source_commit(self, subject, *body):
        self.write("src/Extra.sol", "library Extra {}\n")
        return self.commit(subject, *body)

    def test_documentation_only_has_no_candidate(self):
        self.write("README.md", "updated documentation\n")
        source = self.commit("docs: clarify setup")
        self.assertIsNone(json.loads(self.release("prepare", source).stdout))
        self.assertEqual(self.git("rev-parse", "HEAD"), source)

    def test_candidate_is_deterministic_and_only_changes_release_metadata(self):
        source = self.source_commit("feat(lib): add a helper")
        first = json.loads(self.release("prepare", source).stdout)
        self.assertEqual(first["version"], "1.2.0")
        self.assertEqual(self.git("rev-parse", f'{first["commit"]}^'), source)
        self.assertEqual(self.git("diff", "--name-only", source, first["commit"]).splitlines(),
                         ["CHANGELOG.md", LIBRARY])
        self.assertIn('VERSION = "1.2.0"', self.git("show", f'{first["commit"]}:{LIBRARY}'))
        self.assertIn("add a helper", self.git("show", f'{first["commit"]}:CHANGELOG.md'))
        self.git("checkout", "-q", "--detach", source)
        self.assertEqual(json.loads(self.release("prepare", source).stdout), first)

    def test_breaking_footer_precedes_feature_version(self):
        source = self.source_commit("feat: change an existing helper",
                                    "BREAKING CHANGE: The existing helper now has a different contract.")
        self.assertEqual(json.loads(self.release("prepare", source).stdout)["version"], "2.0.0")

    def test_rejects_manual_version_divergence(self):
        path = self.repo / LIBRARY
        path.write_text(path.read_text().replace("1.1.0", "8.9.0"))
        source = self.commit("fix: adjust the library")
        rejected = self.release("prepare", source, check=False)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("does not match", rejected.stderr)

    def test_retry_reconstructs_tag_and_rejects_a_different_tagged_commit(self):
        source = self.source_commit("fix: correct slot accounting")
        candidate = json.loads(self.release("prepare", source).stdout)
        tag = 'refs/tags/v' + candidate["version"]
        self.git("update-ref", tag, candidate["commit"])
        self.write("src/Next.sol", "library Next {}\n")
        newer_source = self.commit("fix: correct newer storage behavior")
        newest = json.loads(self.release("prepare", newer_source).stdout)
        self.git("update-ref", 'refs/tags/v' + newest["version"], newest["commit"])
        self.assertEqual(json.loads(self.release("retry", candidate["version"], newest["commit"]).stdout),
                         candidate)

        self.git("checkout", "-q", "--detach", source)
        self.write("CHANGELOG.md", "Unexpected release metadata\n")
        tampered = self.commit("chore: edit generated notes")
        self.git("update-ref", tag, tampered)
        rejected = self.release("retry", candidate["version"], tampered, check=False)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("does not match the verified release candidate", rejected.stderr)

    def test_transient_registry_errors_are_not_treated_as_missing_revisions(self):
        from http.client import responses
        from importlib.util import module_from_spec, spec_from_file_location
        from unittest.mock import patch
        from urllib.error import HTTPError
        from io import BytesIO

        spec = spec_from_file_location("release", RELEASE)
        release = module_from_spec(spec)
        spec.loader.exec_module(release)
        missing = b'{"message":"No revisions found","status":"fail"}'
        for status in (HTTPStatus.NOT_FOUND, HTTPStatus.SERVICE_UNAVAILABLE):
            failure = HTTPError("https://api.soldeer.xyz", status, responses[status], None,
                                BytesIO(missing))
            with patch.object(release, "urlopen", side_effect=failure):
                if status == HTTPStatus.NOT_FOUND:
                    self.assertIsNone(release.registry_archive("1.1.0"))
                else:
                    with self.assertRaises(HTTPError):
                        release.registry_archive("1.1.0")

    def test_registry_zip_matches_tagged_source_and_rejects_different_source(self):
        self.write("docs/gas.md", "sample release measurements\n")
        source = self.source_commit("fix: correct slot accounting")
        candidate = json.loads(self.release("prepare", source).stdout)
        self.assertEqual(candidate["version"], "1.1.1")
        files = {
            path: subprocess.check_output(["git", "show", f'{candidate["commit"]}:{path}'], cwd=self.repo)
            for path in ("CHANGELOG.md", "LICENSE", "README.md", "SECURITY.md", "STABILITY.md",
                         "docs/gas.md", LIBRARY, "src/Extra.sol")
        }
        archive = self.repo / "registry.zip"
        for changed in (False, True):
            with zipfile.ZipFile(archive, "w") as package:
                for path, value in files.items():
                    if changed and path == "src/Extra.sol":
                        value += b"// different package\n"
                    package.writestr(path, value)
            checked = self.release("verify-package", candidate["commit"], str(archive), check=False)
            self.assertEqual(checked.returncode == 0, not changed, checked.stderr)
            if changed:
                self.assertIn("src/Extra.sol", checked.stderr)


if __name__ == "__main__":
    unittest.main()
