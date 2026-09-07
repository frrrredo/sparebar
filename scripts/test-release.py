#!/usr/bin/env python3
"""Exercise the boundaries before an artifact can reach local signing."""

import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
COMMIT = "a" * 40


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sparebar-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive()

    def archive(self, extra=None, mode=None, duplicate=False):
        with zipfile.ZipFile(self.root / "Sparebar.zip", "w") as zipped:
            for filename in sorted(release.FILES):
                entry = zipfile.ZipInfo("Sparebar.app/" + filename)
                entry.external_attr = (stat.S_IFREG | 0o644) << 16
                if mode and filename == "Contents/MacOS/Sparebar":
                    entry.external_attr = mode << 16
                zipped.writestr(entry, b"synthetic fixture")
            if extra:
                zipped.writestr(extra, b"not app content")
            if duplicate:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    zipped.writestr("Sparebar.app/Contents/Info.plist", b"duplicate")
        manifest = {"schema": 1, "repository": release.REPO, "commit": COMMIT, "version": "0.1.1", "build": "2", "architecture": "arm64", "minimum_macos": "26.5.1", "archive_sha256": release.digest(self.root / "Sparebar.zip")}
        (self.root / "build.json").write_text(json.dumps(manifest))

    def rejected(self, message):
        with self.assertRaisesRegex(release.ReleaseError, message):
            release.verify_artifact(self.root, COMMIT)

    def test_valid_artifact(self):
        self.assertEqual(release.verify_artifact(self.root, COMMIT)["version"], "0.1.1")

    def test_changed_archive_is_rejected(self):
        with (self.root / "Sparebar.zip").open("ab") as stream:
            stream.write(b"tampered")
        self.rejected("checksum")

    def test_wrong_commit_is_rejected(self):
        with self.assertRaisesRegex(release.ReleaseError, "source"):
            release.verify_artifact(self.root, "b" * 40)

    def test_path_traversal_is_rejected(self):
        self.archive(extra="Sparebar.app/../../escaped")
        self.rejected("paths")

    def test_symlink_is_rejected(self):
        self.archive(mode=stat.S_IFLNK | 0o777)
        self.rejected("link")

    def test_duplicate_entry_is_rejected(self):
        self.archive(duplicate=True)
        self.rejected("Duplicate")

    def test_extra_file_cannot_enter_release(self):
        self.archive(extra="Sparebar.app/Contents/Resources/private.key")
        self.rejected("paths")


class RunTests(unittest.TestCase):
    def record(self):
        return {"workflow_id": 42, "event": "push", "head_branch": "main", "status": "completed", "conclusion": "success", "head_repository": {"full_name": release.REPO}, "head_sha": COMMIT, "run_attempt": 1}

    def test_successful_main_push(self):
        release.verify_run(self.record(), 42)

    def test_untrusted_or_failed_runs(self):
        for field, value in [("event", "pull_request"), ("head_branch", "feature"), ("conclusion", "failure"), ("status", "in_progress"), ("workflow_id", 99), ("head_repository", {"full_name": "someone/fork"})]:
            with self.subTest(field=field):
                record = self.record()
                record[field] = value
                with self.assertRaises(release.ReleaseError):
                    release.verify_run(record, 42)


class PackagingTests(unittest.TestCase):
    def test_untracked_sources_cannot_claim_a_clean_commit(self):
        with tempfile.TemporaryDirectory(prefix="sparebar-source-test-") as temporary:
            repo = Path(temporary)
            release.run("git", "init", "-q", "--initial-branch=fixture", repo)
            release.run("git", "-C", repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-qm", "fixture")
            (repo / "Sources").mkdir()
            (repo / "Sources/Unexpected.swift").write_text("// untracked source\n")
            with patch.object(release, "ROOT", repo):
                with self.assertRaisesRegex(release.ReleaseError, "source changes"):
                    release.archive(repo / "Sparebar.app", repo / "artifact")

    def test_dmg_payload_is_accessible_under_private_umask(self):
        with tempfile.TemporaryDirectory(prefix="sparebar-permissions-test-") as temporary:
            root = Path(temporary)
            app = root / "Sparebar.app"
            app.mkdir()
            (app / "fixture").write_text("sample app")
            previous = os.umask(0o077)
            try:
                source = root / "dmg-source"
                release.stage_dmg(app, source)
                self.assertEqual(stat.S_IMODE(source.stat().st_mode), 0o755)
                self.assertEqual(os.readlink(source / "Applications"), "/Applications")
            finally:
                os.umask(previous)


if __name__ == "__main__":
    unittest.main()
