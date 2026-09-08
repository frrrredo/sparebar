#!/usr/bin/env python3
"""Exercise Sparkle against a loopback feed and a deliberately invalid signed download."""

import base64
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from threading import Thread
import uuid
import xml.etree.ElementTree as ET


def main(app):
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="updater-test-", dir=root / ".build") as temporary:
        work = Path(temporary)
        fixture = work / "SparebarFixture.app"
        subprocess.run(["ditto", str(app), str(fixture)], check=True)
        server = ThreadingHTTPServer(("127.0.0.1", 0), partial(SimpleHTTPRequestHandler, directory=str(work)))
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        feed_url = f"http://127.0.0.1:{server.server_port}/appcast.xml"
        bundle_id = f"io.github.frrrredo.sparebar.fixture.{uuid.uuid4().hex}"
        try:
            info_path = fixture / "Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info.update(CFBundleIdentifier=bundle_id, SUFeedURL=feed_url,
                        SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
                        NSAppTransportSecurity={"NSAllowsLocalNetworking": True})
            info_path.write_bytes(plistlib.dumps(info))
            subprocess.run(["codesign", "--force", "--sign", "-", str(fixture)], check=True)
            ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
            ET.register_namespace("sparkle", ns)
            rss = ET.Element("rss", version="2.0")
            item = ET.SubElement(ET.SubElement(rss, "channel"), "item")
            ET.SubElement(item, "title").text = "Synthetic update"
            ET.SubElement(item, f"{{{ns}}}version").text = str(int(info["CFBundleVersion"]) + 1)
            ET.SubElement(item, f"{{{ns}}}shortVersionString").text = "0.1.4"
            ET.SubElement(item, "description", {f"{{{ns}}}format": "plain-text"}).text = "Less clicking.\n\nUser-friendly details."
            payload = b"Deliberately invalid update data. Never extract or execute."
            (work / "update.zip").write_bytes(payload)
            ET.SubElement(item, "enclosure", {"url": feed_url.replace("appcast.xml", "update.zip"),
                          "length": str(len(payload)), f"{{{ns}}}edSignature": base64.b64encode(bytes(64)).decode()})
            (work / "appcast.xml").write_bytes(ET.tostring(rss))
            env = dict(os.environ, SPAREBAR_UPDATER_FIXTURE=str(fixture), SPAREBAR_UPDATER_REJECT_DOWNLOAD="1")
            subprocess.run(["swift", "test", "--filter", "localAppcastPassesThroughTheRealSparkleDriver"],
                           cwd=root, env=env, check=True, timeout=90)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            subprocess.run(["defaults", "delete", bundle_id], capture_output=True)


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
