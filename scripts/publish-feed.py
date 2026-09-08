#!/usr/bin/env python3
"""Publish a release's appcast to the update branch without changing release assets."""

import argparse
import base64
import json
from pathlib import Path
import re
import subprocess
import urllib.request
import xml.etree.ElementTree as ET

REPO = "frrrredo/sparebar"
BRANCH = "updates"
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", NS)


def api(path, payload=None, optional=False):
    command = ["gh", "api", f"repos/{REPO}/{path}"]
    if payload is not None:
        command += ["--method", "POST" if path == "git/refs" else "PUT", "--input", "-"]
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            capture_output=True, text=True)
    if result.returncode:
        if optional and "HTTP 404" in result.stderr:
            return None
        raise RuntimeError(f"GitHub operation failed: {path}")
    return json.loads(result.stdout)


def validate_feed(data, tag=None):
    if len(data) > 256_000 or b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper():
        raise ValueError("Invalid or oversized appcast")
    root = ET.fromstring(data)
    channel = root.find("channel")
    if root.tag != "rss" or channel is None:
        raise ValueError("Appcast must be RSS with a channel")
    items = channel.findall("item")
    if not 1 <= len(items) <= 20:
        raise ValueError("Appcast must contain 1 to 20 updates")
    builds = set()
    for item in items:
        build = item.findtext(f"{{{NS}}}version", "")
        version = item.findtext(f"{{{NS}}}shortVersionString", "")
        notes = item.find("description")
        enclosure = item.find("enclosure")
        if not re.fullmatch(r"[1-9]\d*", build) or build in builds or not re.fullmatch(r"\d+\.\d+\.\d+", version):
            raise ValueError("Invalid or duplicate update version")
        builds.add(build)
        if tag is not None and tag != f"v{version}":
            raise ValueError("Appcast does not match the published release")
        if notes is None or notes.get(f"{{{NS}}}format") != "plain-text" or list(notes):
            raise ValueError("Release notes must be plain text")
        text = (notes.text or "").strip()
        if not text or len(text) > 12_000 or len(text.splitlines()[0]) > 180:
            raise ValueError("Release notes need a short summary")
        expected_url = f"https://github.com/{REPO}/releases/download/v{version}/Sparebar-{version}-arm64.dmg"
        if enclosure is None or enclosure.get("url") != expected_url:
            raise ValueError("Update must use the exact Sparebar release asset")
        length = enclosure.get("length", "")
        if not length.isdigit() or not 0 < int(length) < 64 * 1024 * 1024:
            raise ValueError("Invalid download length")
        signature = enclosure.get(f"{{{NS}}}edSignature", "")
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError("Missing or invalid update signature")
        allowed = {"title", "description", "enclosure", f"{{{NS}}}version", f"{{{NS}}}shortVersionString", f"{{{NS}}}minimumSystemVersion"}
        if {child.tag for child in item} != allowed or len(item) != len(allowed):
            raise ValueError("Unexpected appcast metadata")
        if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", item.findtext(f"{{{NS}}}minimumSystemVersion", "")):
            raise ValueError("Invalid minimum system version")
    return root, channel, items


def merge_feed(existing, incoming, tag):
    _, _, new_items = validate_feed(incoming, tag)
    if len(new_items) != 1:
        raise ValueError("A published release must provide exactly one update")
    if existing:
        root, channel, old_items = validate_feed(existing)
    else:
        root = ET.Element("rss", version="2.0")
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Sparebar updates"
        old_items = []
    incoming_build = int(new_items[0].findtext(f"{{{NS}}}version"))
    for item in old_items:
        if int(item.findtext(f"{{{NS}}}version")) == incoming_build:
            # A retry must not replace the bytes or metadata of an existing update.
            if ET.tostring(item).strip() != ET.tostring(new_items[0]).strip():
                raise ValueError("An update with this build already exists")
            return existing
    for item in old_items:
        channel.remove(item)
    for item in sorted(old_items + new_items, key=lambda i: int(i.findtext(f"{{{NS}}}version")), reverse=True)[:20]:
        channel.append(item)
    ET.indent(root)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"


def publish(release_id):
    record = api(f"releases/{release_id}")
    if record.get("draft") or not re.fullmatch(r"v\d+\.\d+\.\d+", record.get("tag_name", "")):
        raise ValueError("Expected a published Sparebar version")
    assets = [a for a in record["assets"] if a["name"] == "appcast.xml"]
    if len(assets) != 1 or not 0 < assets[0]["size"] <= 32_000:
        raise ValueError("Release requires one appcast.xml asset")
    expected = f"https://github.com/{REPO}/releases/download/{record['tag_name']}/appcast.xml"
    if assets[0]["browser_download_url"] != expected:
        raise ValueError("Unexpected appcast asset URL")
    with urllib.request.urlopen(expected, timeout=30) as response:
        incoming = response.read(32_001)
    if len(incoming) > 32_000:
        raise ValueError("Appcast asset too large")
    _, _, items = validate_feed(incoming, record["tag_name"])
    enclosure = items[0].find("enclosure")
    downloads = [a for a in record["assets"] if a["browser_download_url"] == enclosure.get("url")]
    if len(downloads) != 1 or downloads[0]["size"] != int(enclosure.get("length")):
        raise ValueError("Signed appcast does not describe the published DMG")
    previous = api(f"contents/appcast.xml?ref={BRANCH}", optional=True)
    existing = base64.b64decode(previous["content"], validate=False) if previous else None
    merged = merge_feed(existing, incoming, record["tag_name"])
    if merged == existing:
        print("Update feed already contains this release.")
        return
    if api(f"git/ref/heads/{BRANCH}", optional=True) is None:
        main = api("git/ref/heads/main")
        api("git/refs", {"ref": f"refs/heads/{BRANCH}", "sha": main["object"]["sha"]})
    payload = {"message": f"Publish update feed for {record['tag_name']}", "branch": BRANCH,
               "content": base64.b64encode(merged).decode()}
    if previous:
        payload["sha"] = previous["sha"]
    api("contents/appcast.xml", payload)
    print("Update feed published.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release_id", type=int)
    publish(parser.parse_args().release_id)
