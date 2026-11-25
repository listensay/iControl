#!/usr/bin/env python3
"""Exercise release failure/retry paths with a fake gh, never a live release."""
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
version = subprocess.check_output(["python3", str(root / "Tools/check-release-version.py")], text=True).strip()
with tempfile.TemporaryDirectory(prefix="icontrol-release-") as directory:
    fixture = Path(directory)
    for name in ("Scripts/publish-mac-release.sh", "Tools/check-release-version.py", "Resources/Info.plist", "Sources/IControlApp/IControlApp.swift"):
        destination = fixture / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, destination)
    (fixture / "bin").mkdir()
    (fixture / "dist").mkdir()
    archive = fixture / f"dist/iControl-{version}-mac.zip"
    archive.write_bytes(b"test package")
    checksum = fixture / "dist/SHA256SUMS.txt"
    checksum.write_text(f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n")
    fake_gh = fixture / "bin/gh"
    fake_gh.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['RELEASE_CALLS'], 'a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
state = os.environ['RELEASE_STATE']
if sys.argv[1] == 'api':
    if state == 'api-failure': sys.exit(1)
    if state == 'published': print('false')
    if state == 'draft': print('true')
if sys.argv[1:3] == ['release', 'upload'] and state == 'upload-failure': sys.exit(1)
''')
    fake_gh.chmod(0o755)
    calls_file = fixture / "calls.jsonl"

    def run(state, tag="v" + version):
        calls_file.write_text("")
        environment = dict(os.environ, PATH=str(fixture / "bin") + os.pathsep + os.environ["PATH"],
                           GITHUB_REPOSITORY="example/icontrol", RELEASE_STATE=state, RELEASE_CALLS=str(calls_file))
        result = subprocess.run(["bash", str(fixture / "Scripts/publish-mac-release.sh"), tag],
                                env=environment, capture_output=True, text=True)
        return result, [json.loads(line) for line in calls_file.read_text().splitlines()]

    result, calls = run("new")
    assert result.returncode == 0, result.stderr
    assert [call[:2] for call in calls[1:]] == [["release", "create"], ["release", "upload"], ["release", "edit"]]
    assert "--draft" in calls[1] and "--verify-tag" in calls[1]
    assert "--draft=false" in calls[-1]
    assert [argument for argument in calls[2] if argument.startswith("dist/")] == [f"dist/{archive.name}", "dist/SHA256SUMS.txt"]

    result, calls = run("draft")
    assert result.returncode == 0 and [call[:2] for call in calls[1:]] == [["release", "upload"], ["release", "edit"]]
    result, calls = run("published")
    assert result.returncode == 0 and len(calls) == 1
    result, calls = run("upload-failure")
    assert result.returncode != 0 and not any(call[:2] == ["release", "edit"] for call in calls)
    result, calls = run("api-failure")
    assert result.returncode != 0 and len(calls) == 1
    for tag in ("v999.0.0", "v" + version + "-beta", "v01.4.5", "v1.4.5;echo injected"):
        result, calls = run("new", tag)
        assert result.returncode != 0 and not calls
    original_checksum = checksum.read_text()
    checksum.write_text(original_checksum + "0" * 64 + "  source.zip\n")
    result, calls = run("new")
    assert result.returncode != 0 and not calls
    checksum.write_text(original_checksum)
    archive.write_bytes(b"corrupted package")
    result, calls = run("new")
    assert result.returncode != 0 and not calls
print("Release checks: new/draft/published releases, failed upload/API, invalid tags, Mac-only checksums, and corrupt assets OK")
