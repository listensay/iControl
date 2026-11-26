"""Check that the bundled iPad daemon and corresponding sources match the release inputs."""
import hashlib
import json
import plistlib
import tarfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sources = root / "Device/FPSDaemon"
resources = root / "Sources/IControlApp/Resources"
daemon = resources / "FPSDaemon"
version = plistlib.loads((sources / "Info.plist").read_bytes())["CFBundleShortVersionString"]
manifest = json.loads((daemon / "manifest.json").read_text())
digest = hashlib.sha256((daemon / "icontrol-fpsd").read_bytes()).hexdigest()
if manifest["version"] != version or manifest["sha256"] != digest:
    raise SystemExit("Bundled iPad daemon does not match its version or SHA-256 manifest")

expected = {f"FPSDaemon/{p.relative_to(sources)}": p for p in sources.rglob("*") if p.is_file()}
with tarfile.open(resources / f"ThirdPartySources/iControl-FPSDaemon-{version}-source.tar.gz") as archive:
    for member in archive.getmembers():
        if member.isdir():
            continue
        source = expected.pop(member.name, None)
        if source is None or not member.isfile() or archive.extractfile(member).read() != source.read_bytes():
            raise SystemExit(f"Bundled iPad source mismatch: {member.name}")
if expected:
    raise SystemExit(f"Missing bundled iPad sources: {', '.join(sorted(expected))}")
print(f"iPad daemon {version}: SHA-256 {digest}, matching source archive")
