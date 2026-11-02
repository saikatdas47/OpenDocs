#!/usr/bin/env python3
"""Restore the pinned Android office engine. No third-party Python packages required."""
from pathlib import Path
import argparse
import hashlib
import shutil
import tempfile
import urllib.request
import zipfile

URL = "https://f-droid.org/repo/org.documentfoundation.libreoffice_131.apk"
SHA256 = "751ac3836890b79a56801bf6d9a2788cda3761ab5131a4f0b6abfbad822bb475"
ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, help="Use an already downloaded official APK")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="opendocs-engine-") as temporary:
        apk = args.apk
        if apk is None:
            apk = Path(temporary) / "engine.apk"
            print("Downloading pinned LibreOffice engine (about 88 MB)…")
            with urllib.request.urlopen(URL, timeout=120) as source, apk.open("wb") as target:
                shutil.copyfileobj(source, target)
        digest = hashlib.sha256()
        with apk.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != SHA256:
            raise SystemExit("Engine checksum mismatch. No files installed.")
        destination = ROOT / "android/app/src/main"
        count = 0
        with zipfile.ZipFile(apk) as archive:
            for item in archive.infolist():
                name = item.filename
                if item.is_dir():
                    continue
                if name.startswith("lib/arm64-v8a/"):
                    relative = Path("jniLibs") / name.removeprefix("lib/")
                elif any(name.startswith("assets/" + folder + "/") for folder in ("program", "share", "unpack")):
                    relative = Path(name)
                else:
                    continue
                if ".." in relative.parts or relative.is_absolute():
                    raise SystemExit("Unsafe archive path")
                target = destination / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(item) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
                count += 1
        assert (destination / "jniLibs/arm64-v8a/liblo-native-code.so").is_file()
        print(f"Verified and installed {count} engine files. They are excluded from Git.")

if __name__ == "__main__":
    main()
