#!/bin/bash
set -euo pipefail
ICONTROL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ICONTROL_ROOT"
ICONTROL_TAG="${1:?Pass the release tag}"
ICONTROL_VERSION="$(python3 Tools/check-release-version.py --tag "$ICONTROL_TAG")"
ICONTROL_REPOSITORY="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
ICONTROL_ZIP="iControl-$ICONTROL_VERSION-mac.zip"
test -f "dist/$ICONTROL_ZIP"
test -f dist/SHA256SUMS.txt
python3 - "$ICONTROL_ZIP" <<'PY'
import re, sys
from pathlib import Path
checksums = Path('dist/SHA256SUMS.txt').read_text().strip()
if not re.fullmatch(r'[a-f0-9]{64}  ' + re.escape(sys.argv[1]), checksums):
    sys.exit('Release checksums must contain exactly the Mac ZIP')
PY
(
  cd dist
  shasum -a 256 -c SHA256SUMS.txt
)
# A stable numeric tag was validated above before interpolation into the jq filter.
ICONTROL_DRAFT="$(gh api --paginate "repos/$ICONTROL_REPOSITORY/releases?per_page=100" \
  --jq ".[] | select(.tag_name == \"$ICONTROL_TAG\") | .draft")"
if [ "$ICONTROL_DRAFT" = false ]; then
  printf 'Release %s is already published; leaving it intact.\n' "$ICONTROL_TAG"
  exit 0
fi
if [ -z "$ICONTROL_DRAFT" ]; then
  mkdir -p work
  cat > work/release-notes.md <<EOF
Mac package for Apple Silicon, macOS 14 or later. Includes the iPad services, viewer, source/license notices, and bilingual documentation. Ad-hoc signed; not notarized.

Download the Mac ZIP and SHA256SUMS.txt into the same folder, then run \`shasum -a 256 -c SHA256SUMS.txt\`.

[English setup guide](https://github.com/$ICONTROL_REPOSITORY/blob/$ICONTROL_TAG/docs/SETUP.md) · [中文准备与使用教程](https://github.com/$ICONTROL_REPOSITORY/blob/$ICONTROL_TAG/docs/SETUP.zh-CN.md)

仅发布 Apple Silicon Mac 包与校验文件。设备控制端和中英文文档内置于应用中；当前采用临时签名，尚未公证。
EOF
  gh release create "$ICONTROL_TAG" --repo "$ICONTROL_REPOSITORY" --verify-tag \
    --draft --title "iControl $ICONTROL_VERSION" --notes-file work/release-notes.md
fi
gh release upload "$ICONTROL_TAG" "dist/$ICONTROL_ZIP" dist/SHA256SUMS.txt \
  --repo "$ICONTROL_REPOSITORY" --clobber
gh release edit "$ICONTROL_TAG" --repo "$ICONTROL_REPOSITORY" --draft=false --latest
