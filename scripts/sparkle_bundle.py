"""Bundle the pinned Sparkle framework and sign its nested code from the inside out."""

import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
ARTIFACT = ROOT / ".build/artifacts/sparkle/Sparkle"
FRAMEWORK = "Contents/Frameworks/Sparkle.framework"
NESTED_CODE = [
    "Versions/B/XPCServices/Downloader.xpc",
    "Versions/B/XPCServices/Installer.xpc",
    "Versions/B/Autoupdate",
    "Versions/B/Updater.app",
    ".",
]


def inventory():
    return json.loads((ROOT / "Resources/Sparkle-files.json").read_text())


def sign(app, identity, timestamp=False):
    for relative in NESTED_CODE:
        command = ["codesign", "--force", "--sign", identity, "--options", "runtime",
                   "--preserve-metadata=entitlements"]
        if timestamp:
            command.append("--timestamp")
        subprocess.run(command + [str(Path(app) / FRAMEWORK / relative)], check=True)


def embed(app):
    source = ARTIFACT / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    destination = Path(app) / FRAMEWORK
    if not source.is_dir():
        raise RuntimeError("Resolve the pinned Sparkle package before packaging.")
    if destination.is_symlink():
        raise RuntimeError("Refusing to replace a linked framework directory.")
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, symlinks=True)
    resources = Path(app) / "Contents/Resources"
    shutil.copyfile(ARTIFACT / "LICENSE", resources / "Sparkle-LICENSE")
    shutil.copyfile(ROOT / "Resources/ReleaseNotes.txt", resources / "ReleaseNotes.txt")
    sign(app, "-")


if __name__ == "__main__":
    embed(Path(sys.argv[1]))
