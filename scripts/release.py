#!/usr/bin/env python3
"""Archive a CI build, or notarize that exact build using a local Keychain."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import zipfile
import xml.etree.ElementTree as ET

import sparkle_bundle

REPO = "frrrredo/sparebar"
ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "io.github.frrrredo.sparebar"
FILES = {
    "Contents/Info.plist", "Contents/MacOS/Sparebar",
    "Contents/Resources/LICENSE", "Contents/Resources/Sparebar.icns",
    "Contents/_CodeSignature/CodeResources",
    "Contents/Resources/Sparkle-LICENSE", "Contents/Resources/ReleaseNotes.txt",
}
FRAMEWORK = sparkle_bundle.FRAMEWORK
SPARKLE = sparkle_bundle.inventory()
FILES |= {f"{FRAMEWORK}/{path}" for path in SPARKLE["files"]}
LINKS = {f"{FRAMEWORK}/{path}": target for path, target in SPARKLE["links"].items()}
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


class ReleaseError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def run(*args):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True)
    require(result.returncode == 0, f"{Path(str(args[0])).name} {args[1]} failed (exit {result.returncode}).")
    return result.stdout


def digest(path):
    checksum = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def api(path):
    return json.loads(run("gh", "api", f"repos/{REPO}/{path}"))


def bundle_info(app, commit, strict_contents=True):
    require(app.is_dir() and not app.is_symlink(), "Expected a real Sparebar.app directory.")
    files = {str(path.relative_to(app)) for path in app.rglob("*") if path.is_file() and not path.is_symlink()}
    links = {str(path.relative_to(app)): os.readlink(path) for path in app.rglob("*") if path.is_symlink()}
    require(links == LINKS, "App contains an unexpected link.")
    require(all((app / path).resolve().is_relative_to((app / FRAMEWORK).resolve()) for path in links), "Framework link escapes its bundle.")
    if strict_contents:
        require(files == FILES, "Unexpected app contents.")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info.get("CFBundleIdentifier") == BUNDLE_ID, "Wrong bundle identifier.")
    require(info.get("SparebarSourceRevision") == commit, "App source revision does not match the CI run.")
    require(info.get("LSMinimumSystemVersion") == "26.5.1", "Unexpected macOS baseline.")
    require(re.fullmatch(r"\d+\.\d+\.\d+", info.get("CFBundleShortVersionString", "")), "Invalid version.")
    require(re.fullmatch(r"[1-9]\d*", info.get("CFBundleVersion", "")), "Invalid build number.")
    require(os.access(app / "Contents/MacOS/Sparebar", os.X_OK), "App binary is not executable.")
    require(run("lipo", "-archs", app / "Contents/MacOS/Sparebar").strip() == "arm64", "App must be arm64 only.")
    run("codesign", "--verify", "--deep", "--strict", app)
    return info


def archive(app, output):
    require(not output.exists(), "Artifact output already exists; choose a new directory.")
    require(not run("git", "-C", ROOT, "status", "--porcelain", "--untracked-files=all").strip(), "Commit all source changes before archiving a release build.")
    commit = run("git", "-C", ROOT, "rev-parse", "HEAD").strip()
    info = bundle_info(app, commit)
    output.mkdir(parents=True)
    path = output / "Sparebar.zip"
    run("ditto", "-c", "-k", "--norsrc", "--keepParent", app, path)
    manifest = {
        "schema": 1, "repository": REPO, "commit": commit,
        "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
        "architecture": "arm64", "minimum_macos": "26.5.1", "archive_sha256": digest(path),
    }
    (output / "build.json").write_text(json.dumps(manifest, indent=2) + "\n")
    verify_artifact(output, commit)
    print(f"Archived Sparebar {manifest['version']} from {commit}.")


def verify_artifact(directory, commit):
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "Invalid source commit.")
    require({p.name for p in directory.iterdir()} == {"Sparebar.zip", "build.json"}, "Unexpected artifact contents.")
    require(all(p.is_file() and not p.is_symlink() for p in directory.iterdir()), "Artifact files must be regular files.")
    require((directory / "build.json").stat().st_size < 16_384, "Build manifest is too large.")
    manifest = json.loads((directory / "build.json").read_text())
    require(type(manifest) is dict and type(manifest.get("schema")) is int and manifest["schema"] == 1, "Invalid build manifest.")
    require(manifest.get("repository") == REPO and manifest.get("commit") == commit, "Artifact source does not match the CI run.")
    require(manifest.get("architecture") == "arm64" and manifest.get("minimum_macos") == "26.5.1", "Unexpected artifact platform.")
    for field, pattern in [("version", r"\d+\.\d+\.\d+"), ("build", r"[1-9]\d*"), ("archive_sha256", r"[0-9a-f]{64}")]:
        require(type(manifest.get(field)) is str and re.fullmatch(pattern, manifest[field]), f"Invalid artifact {field}.")
    archive_path = directory / "Sparebar.zip"
    require(archive_path.stat().st_size < 64 * 1024 * 1024, "Archive is too large.")
    require(digest(archive_path) == manifest["archive_sha256"], "Archive checksum mismatch.")
    expected = {"Sparebar.app/" + path for path in FILES | LINKS.keys()}
    directories = {str(parent) + "/" for path in expected for parent in Path(path).parents if str(parent) != "."}
    with zipfile.ZipFile(archive_path) as zipped:
        entries = zipped.infolist()
        require(len({entry.filename for entry in entries}) == len(entries), "Duplicate archive entries.")
        require(sum(entry.file_size for entry in entries) < 100 * 1024 * 1024, "Expanded archive is too large.")
        require({entry.filename for entry in entries if not entry.is_dir()} == expected, "Unexpected archive paths.")
        for entry in entries:
            mode = stat.S_IFMT(entry.external_attr >> 16)
            relative = entry.filename.removeprefix("Sparebar.app/")
            if relative in LINKS:
                require(mode == stat.S_IFLNK and entry.file_size < 256, "Invalid framework link.")
                require(zipped.read(entry).decode("utf-8") == LINKS[relative], "Unexpected framework link target.")
            else:
                require(mode in (0, stat.S_IFREG, stat.S_IFDIR), "Archive contains a link or special file.")
            require(entry.filename in expected | directories, "Unsafe archive path.")
        require(zipped.testzip() is None, "Archive data is corrupt.")
    return manifest


def verify_run(record, workflow_id):
    require(record.get("workflow_id") == workflow_id, "Run is not from Sparebar CI.")
    require(record.get("event") == "push" and record.get("head_branch") == "main", "Only a main-branch push build can be released.")
    require(record.get("status") == "completed" and record.get("conclusion") == "success", "CI run has not passed.")
    require(record.get("head_repository", {}).get("full_name") == REPO, "Run belongs to a different repository.")
    require(re.fullmatch(r"[0-9a-f]{40}", record.get("head_sha", "")), "Invalid CI source commit.")
    require(type(record.get("run_attempt")) is int and record["run_attempt"] > 0, "Invalid CI attempt.")


def signed(path, team, runtime=False):
    run("codesign", "--verify", "--strict", path)
    result = subprocess.run(["codesign", "--display", "--verbose=4", str(path)], capture_output=True, text=True)
    require(result.returncode == 0, "Cannot read code signature.")
    lines = result.stderr.splitlines()
    require(f"TeamIdentifier={team}" in lines, "Signature uses the wrong developer team.")
    require(any(line.startswith("Authority=Developer ID Application:") for line in lines), "A Developer ID Application certificate is required.")
    require(any(line.startswith("Timestamp=") for line in lines), "Signature has no secure timestamp.")
    if runtime:
        require(any("flags=" in line and "(runtime)" in line for line in lines), "Hardened Runtime is missing.")
        entitlements = run("codesign", "--display", "--entitlements", ":-", path).strip()
        require(not entitlements or plistlib.loads(entitlements.encode()) == {}, "Release app has unexpected entitlements.")


def stage_dmg(app, source):
    source.mkdir()
    # The distributed volume must not inherit the private working directory's mode.
    source.chmod(0o755)
    run("ditto", app, source / "Sparebar.app")
    (source / "Applications").symlink_to("/Applications")


def notarize(path, profile, work, label):
    print(f"Notarizing {label}...", flush=True)
    result = subprocess.run([
        "xcrun", "notarytool", "submit", str(path), "--keychain-profile", profile,
        "--wait", "--timeout", "30m", "--output-format", "json",
    ], capture_output=True, text=True)
    diagnostics = ROOT / "dist/notary-logs"
    diagnostics.mkdir(parents=True, exist_ok=True)
    response_path = diagnostics / f"{work.name}-{label}.json"
    response_path.write_text(result.stdout)
    error_path = response_path.with_suffix(".stderr")
    error_path.write_text(result.stderr)
    require(result.returncode == 0, f"Apple submission failed; local details: {response_path}")
    response = json.loads(result.stdout)
    submission = response.get("id", "")
    require(re.fullmatch(r"[0-9a-fA-F-]{36}", submission), "Apple returned an invalid submission ID.")
    log_path = diagnostics / f"{submission}.json"
    run("xcrun", "notarytool", "log", submission, "--keychain-profile", profile, log_path)
    log = json.loads(log_path.read_text())
    require(response.get("status") == "Accepted", f"Apple did not accept {label}; inspect {log_path}")
    require(not log.get("issues"), f"Apple returned diagnostics requiring review: {log_path}")
    return submission


def prepare(args):
    require(re.fullmatch(r"[1-9]\d*", args.run_id), "CI run ID must be numeric.")
    require(re.fullmatch(r"[0-9a-fA-F]{40}", args.identity), "Use the certificate SHA-1 from security find-identity.")
    require(re.fullmatch(r"[A-Z0-9]{10}", args.team_id), "Invalid developer team ID.")
    record = api(f"actions/runs/{args.run_id}")
    verify_run(record, api("actions/workflows/ci.yml")["id"])
    commit = record["head_sha"]
    require(api(f"compare/{commit}...main").get("status") in ("ahead", "identical"), "CI source is no longer on main.")
    with tempfile.TemporaryDirectory(prefix="sparebar-release-") as temporary:
        work = Path(temporary)
        artifact = work / "artifact"
        name = f"sparebar-macos-{commit}-{record['run_attempt']}"
        run("gh", "run", "download", args.run_id, "--repo", REPO, "--name", name, "--dir", artifact)
        manifest = verify_artifact(artifact, commit)
        output = args.output or ROOT / "dist/releases" / manifest["version"]
        require(not output.exists(), "Release output already exists; choose a new directory.")
        app_dir = work / "app"
        run("ditto", "-x", "-k", artifact / "Sparebar.zip", app_dir)
        app = app_dir / "Sparebar.app"
        info = bundle_info(app, commit)
        require(info["CFBundleShortVersionString"] == manifest["version"] and info["CFBundleVersion"] == manifest["build"], "App version does not match its manifest.")
        print(f"Signing CI run {args.run_id}, commit {commit} (no rebuild).", flush=True)
        sparkle_bundle.sign(app, args.identity, timestamp=True)
        for relative in sparkle_bundle.NESTED_CODE:
            signed(app / FRAMEWORK / relative, args.team_id)
        run("codesign", "--force", "--timestamp", "--options", "runtime", "--sign", args.identity, app)
        signed(app, args.team_id, runtime=True)
        app_zip = work / "notary-app.zip"
        run("ditto", "-c", "-k", "--keepParent", app, app_zip)
        app_submission = notarize(app_zip, args.notary_profile, work, "app")
        # ZIP files cannot carry tickets; staple the app that was inside it.
        run("xcrun", "stapler", "staple", app)
        run("xcrun", "stapler", "validate", app)
        run("spctl", "--assess", "--type", "execute", app)
        dmg_source = work / "dmg-source"
        stage_dmg(app, dmg_source)
        filename = f"Sparebar-{manifest['version']}-arm64.dmg"
        dmg = work / filename
        run("hdiutil", "create", "-fs", "HFS+", "-format", "UDZO", "-volname", "Sparebar", "-srcfolder", dmg_source, dmg)
        run("codesign", "--force", "--timestamp", "--sign", args.identity, dmg)
        signed(dmg, args.team_id)
        dmg_submission = notarize(dmg, args.notary_profile, work, "dmg")
        run("xcrun", "stapler", "staple", dmg)
        run("xcrun", "stapler", "validate", dmg)
        run("hdiutil", "verify", dmg)
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", dmg)
        mount = work / "mounted"
        mount.mkdir()
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg)
        try:
            installed = work / "installed/Sparebar.app"
            run("ditto", mount / "Sparebar.app", installed)
            bundle_info(installed, commit, strict_contents=False)
            signed(installed, args.team_id, runtime=True)
            run("xcrun", "stapler", "validate", installed)
            run("spctl", "--assess", "--type", "execute", installed)
            require((mount / "Applications").is_symlink() and os.readlink(mount / "Applications") == "/Applications", "DMG is missing its Applications link.")
        finally:
            run("hdiutil", "detach", mount)
        manifest.update(ci_run_id=args.run_id, ci_run_attempt=record["run_attempt"], dmg_sha256=digest(dmg), developer_team=args.team_id, app_submission=app_submission, dmg_submission=dmg_submission)
        output.mkdir(parents=True)
        (output / filename).write_bytes(dmg.read_bytes())
        write_appcast(output / "appcast.xml", dmg, manifest, app, args.sparkle_account)
        (output / "SHA256SUMS").write_text(f"{manifest['dmg_sha256']}  {filename}\n")
        (output / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"Verified notarized release: {output}")


def write_appcast(destination, dmg, manifest, app, account):
    """Sign the finished DMG, then describe those immutable bytes in the update feed."""
    signer = sparkle_bundle.ARTIFACT / "bin/sign_update"
    key_tool = sparkle_bundle.ARTIFACT / "bin/generate_keys"
    public_key = run(key_tool, "--account", account, "-p").strip()
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(public_key == info.get("SUPublicEDKey"), "Sparkle signing key does not match the archived app.")
    signature = run(signer, "--account", account, "-p", dmg).strip()
    require(len(base64.b64decode(signature, validate=True)) == 64, "Invalid update signature.")
    run(signer, "--account", account, "--verify", dmg, signature)
    notes = (app / "Contents/Resources/ReleaseNotes.txt").read_text().strip()
    require(0 < len(notes) <= 12_000 and len(notes.splitlines()[0]) <= 180, "Release notes need a short first line and at most 12000 characters.")
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Sparebar updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Sparebar {manifest['version']}"
    ET.SubElement(item, "description", {f"{{{SPARKLE_NS}}}format": "plain-text"}).text = notes
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = manifest["build"]
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = manifest["version"]
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = manifest["minimum_macos"]
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/{REPO}/releases/download/v{manifest['version']}/{dmg.name}",
        "length": str(dmg.stat().st_size), "type": "application/octet-stream",
        f"{{{SPARKLE_NS}}}edSignature": signature,
    })
    ET.indent(root)
    destination.write_bytes(ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n")
    manifest["appcast_sha256"] = digest(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("archive", help="Archive an already-built app for CI")
    build.add_argument("app", type=Path)
    build.add_argument("output", type=Path)
    verify = commands.add_parser("verify", help="Check an artifact's source, checksum, and archive paths")
    verify.add_argument("directory", type=Path)
    verify.add_argument("commit")
    release = commands.add_parser("prepare", help="Sign and notarize an exact successful main CI build locally")
    release.add_argument("run_id")
    release.add_argument("--identity", required=True)
    release.add_argument("--team-id", required=True)
    release.add_argument("--notary-profile", required=True)
    release.add_argument("--output", type=Path)
    release.add_argument("--sparkle-account", default="sparebar")
    args = parser.parse_args()
    try:
        os.umask(0o077)
        if args.command == "archive":
            archive(args.app, args.output)
        elif args.command == "verify":
            verify_artifact(args.directory, args.commit)
            print("Artifact verified.")
        else:
            prepare(args)
    except (ReleaseError, OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
