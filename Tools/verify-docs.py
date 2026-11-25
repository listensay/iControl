#!/usr/bin/env python3
"""Check local documentation links in a checkout or packaged resource folder."""
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
documents = [root / name for name in ("README.md", "README.zh-CN.md", "docs/SETUP.md", "docs/SETUP.zh-CN.md")]
errors = []
links = 0
for document in documents:
    if not document.is_file():
        errors.append(f"Missing document: {document}")
        continue
    text = document.read_text()
    for match in re.finditer(r"!?\[[^\]]*\]\(([^)\s]+)\)", text):
        target = urlsplit(match.group(1))
        if target.scheme or target.netloc:
            continue
        path = (document.parent / unquote(target.path)).resolve() if target.path else document
        links += 1
        if not path.is_relative_to(root) or not path.is_file():
            errors.append(f"{document.relative_to(root)}: missing local link {match.group(1)}")
            continue
        if target.fragment and path.suffix == ".md":
            anchors = []
            for heading in re.findall(r"^#{1,6}\s+(.+)$", path.read_text(), re.MULTILINE):
                slug = re.sub(r"[^\w\-\s]", "", heading.lower()).replace(" ", "-")
                anchors.append(slug)
            if unquote(target.fragment) not in anchors:
                errors.append(f"{document.relative_to(root)}: missing heading {match.group(1)}")
if errors:
    sys.exit("\n".join(errors))
print(f"Documentation: {len(documents)} documents, {links} local links/images OK")
