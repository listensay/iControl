#!/usr/bin/env python3
"""Reject inconsistent app metadata and release tags before a build."""
import argparse
import plistlib
import re
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--tag", help="Stable release tag, e.g. v1.4.5")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
metadata = plistlib.loads((root / "Resources/Info.plist").read_bytes())
version = metadata["CFBundleShortVersionString"]
build = metadata["CFBundleVersion"]
source = (root / "Sources/IControlApp/IControlApp.swift").read_text()

def require(condition, message):
    if not condition:
        parser.exit(1, message + "\n")

require(re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version), "Invalid stable app version")
require(re.fullmatch(r"[1-9]\d*", build), "Build number must be a positive integer")
require(f'static let version = "{version}"' in source, "Swift and Info.plist versions differ")
require(f'?? "{build}"' in source, "Swift and Info.plist build numbers differ")
if args.tag is not None:
    require(args.tag == "v" + version, f"Release tag must be v{version}; got {args.tag!r}")
print(version)
