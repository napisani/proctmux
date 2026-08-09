#!/bin/bash
set -euo pipefail

# Update Formula/proctmux.rb with SHA256 checksums for a given release tag.
# Usage: scripts/update-brew.sh <tag>
# Example: scripts/update-brew.sh v0.1.7
#
# Compatible with bash 3.x (macOS default).

TAG="${1:-}"
if [ -z "$TAG" ]; then
	echo "Usage: $0 <tag>" >&2
	echo "Example: $0 v0.1.7" >&2
	exit 1
fi

# Strip leading 'v' for the version line in the formula
VERSION="${TAG#v}"

REPO="napisani/proctmux"
FORMULA="Formula/proctmux.rb"

if [ ! -f "$FORMULA" ]; then
	echo "Error: $FORMULA not found. Run this from the repo root." >&2
	exit 1
fi

PLATFORMS=(
	"darwin-arm64"
	"darwin-amd64"
	"linux-arm64"
	"linux-amd64"
)

DOWNLOAD_DIR=$(mktemp -d)
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT

echo "Updating ${FORMULA} for ${TAG}..."
echo ""

# Update version line (no v prefix)
sed -i.bak "s/^  version \".*\"/  version \"${VERSION}\"/" "$FORMULA"
rm -f "${FORMULA}.bak"

for platform in "${PLATFORMS[@]}"; do
	tarball="proctmux-${platform}.tar.gz"
	url="https://github.com/${REPO}/releases/download/${TAG}/${tarball}"

	echo "Downloading ${tarball}..."
	if ! curl -fSL --retry 3 -o "${DOWNLOAD_DIR}/${tarball}" "$url"; then
		echo "Error: Failed to download ${url}" >&2
		echo "Does release ${TAG} exist with artifact ${tarball}?" >&2
		exit 1
	fi

	sha=$(shasum -a 256 "${DOWNLOAD_DIR}/${tarball}" | awk '{print $1}')
	echo "  SHA256: ${sha}"

	# Use awk to find the url line containing this platform and replace the sha256 on the next line
	awk -v sha="$sha" '
		/url.*proctmux-'"$platform"'/ { print; found=1; next }
		found && /sha256/ { sub(/"[^"]*"/, "\"" sha "\""); found=0 }
		{ print }
	' "$FORMULA" >"${FORMULA}.tmp"
	mv "${FORMULA}.tmp" "$FORMULA"
done

echo ""
echo "Done! Formula updated to version ${VERSION} (tag ${TAG})"
echo ""
echo "Next steps:"
echo "  1. Review: git diff Formula/proctmux.rb"
echo "  2. Commit: git add Formula/proctmux.rb && git commit -m 'brew: update formula to ${TAG}'"
echo "  3. Push to main so 'brew tap' picks it up"
