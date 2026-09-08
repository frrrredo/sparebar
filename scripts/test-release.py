#!/usr/bin/env python3
"""Exercise the boundaries before an artifact can reach local signing."""

import importlib.util
import base64
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
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
feed_spec = importlib.util.spec_from_file_location("publish_feed", Path(__file__).with_name("publish-feed.py"))
feed = importlib.util.module_from_spec(feed_spec)
feed_spec.loader.exec_module(feed)
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
            for filename, target in release.LINKS.items():
                entry = zipfile.ZipInfo("Sparebar.app/" + filename)
                entry.external_attr = (stat.S_IFLNK | 0o755) << 16
                zipped.writestr(entry, target.encode())
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


class FeedTests(unittest.TestCase):
    def item(self, version="0.1.3", build="4"):
        ns = feed.NS
        root = ET.Element("rss", version="2.0")
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Sparebar updates"
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = f"Sparebar {version}"
        ET.SubElement(item, "description", {f"{{{ns}}}format": "plain-text"}).text = "Less clicking.\n\nUser-friendly details."
        ET.SubElement(item, f"{{{ns}}}version").text = build
        ET.SubElement(item, f"{{{ns}}}shortVersionString").text = version
        ET.SubElement(item, f"{{{ns}}}minimumSystemVersion").text = "26.5.1"
        ET.SubElement(item, "enclosure", {"url": f"https://github.com/{feed.REPO}/releases/download/v{version}/Sparebar-{version}-arm64.dmg",
                     "length": "123456", f"{{{ns}}}edSignature": base64.b64encode(bytes(64)).decode()})
        ET.indent(root)
        return ET.tostring(root)

    def test_first_feed_and_retry_are_identical(self):
        incoming = self.item()
        first = feed.merge_feed(None, incoming, "v0.1.3")
        self.assertEqual(feed.merge_feed(first, incoming, "v0.1.3"), first)

    def test_out_of_order_publication_never_downgrades_latest(self):
        newer = feed.merge_feed(None, self.item("0.1.4", "5"), "v0.1.4")
        merged = feed.merge_feed(newer, self.item(), "v0.1.3")
        items = feed.validate_feed(merged)[2]
        self.assertEqual([i.findtext(f"{{{feed.NS}}}version") for i in items], ["5", "4"])

    def test_existing_build_cannot_be_replaced(self):
        first = feed.merge_feed(None, self.item(), "v0.1.3")
        changed = self.item().replace(b"123456", b"654321")
        with self.assertRaisesRegex(ValueError, "already exists"):
            feed.merge_feed(first, changed, "v0.1.3")

    def test_untrusted_links_or_unsigned_updates_are_rejected(self):
        cases = [self.item().replace(b"github.com/frrrredo", b"example.com/frrrredo"),
                 self.item().replace(base64.b64encode(bytes(64)), b"invalid"),
                 self.item().replace(b"plain-text", b"text/html"),
                 b'<!DOCTYPE rss [<!ENTITY x "unsafe">]>' + self.item()]
        for data in cases:
            with self.subTest(data=data[:40]), self.assertRaises(ValueError):
                feed.validate_feed(data, "v0.1.3")

    def test_wrong_release_tag_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            feed.validate_feed(self.item(), "v0.1.4")

    def test_unexpected_metadata_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "metadata"):
            feed.validate_feed(self.item().replace(b"</item>", b"<link>https://example.com</link></item>"))


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
