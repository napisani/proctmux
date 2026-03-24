#!/usr/bin/env bash
# Builds libghostty-vt.a static libraries and copies headers for proctmux.
#
# Requires: zig 0.15.x, git
# Usage: ./scripts/build-libghostty.sh [ghostty-commit-hash]
#
# By default, builds for the current platform only. Pass "all" as the
# second argument to build for all supported platforms:
#   ./scripts/build-libghostty.sh main all

set -euo pipefail

GHOSTTY_COMMIT="${1:-main}"
BUILD_ALL="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../internal/terminal/ghosttyvt/lib"

# Verify zig is available.
if ! command -v zig &>/dev/null; then
	echo "ERROR: zig is required but not found on PATH."
	echo "Install with: brew install zig (macOS) or see https://ziglang.org/download/"
	exit 1
fi

echo "Using zig $(zig version)"

# Clone or update ghostty source.
GHOSTTY_SRC="/tmp/ghostty-src"
if [ ! -d "$GHOSTTY_SRC/.git" ]; then
	echo "Cloning ghostty..."
	rm -rf "$GHOSTTY_SRC"
	git clone https://github.com/ghostty-org/ghostty.git "$GHOSTTY_SRC"
fi

cd "$GHOSTTY_SRC"
git fetch origin
git checkout "$GHOSTTY_COMMIT" 2>/dev/null || git checkout "origin/$GHOSTTY_COMMIT"
echo "Building from commit: $(git rev-parse HEAD)"

# Determine which targets to build.
if [ "$BUILD_ALL" = "all" ]; then
	TARGETS="aarch64-macos x86_64-macos aarch64-linux x86_64-linux"
else
	# Build for current platform only.
	ARCH="$(uname -m)"
	OS="$(uname -s)"
	case "$OS" in
	Darwin) ZIG_OS="macos" ;;
	Linux) ZIG_OS="linux" ;;
	*)
		echo "ERROR: Unsupported OS: $OS"
		exit 1
		;;
	esac
	case "$ARCH" in
	arm64 | aarch64) ZIG_ARCH="aarch64" ;;
	x86_64) ZIG_ARCH="x86_64" ;;
	*)
		echo "ERROR: Unsupported architecture: $ARCH"
		exit 1
		;;
	esac
	TARGETS="${ZIG_ARCH}-${ZIG_OS}"
fi

# Build for each target.
for target in $TARGETS; do
	echo ""
	echo "=== Building libghostty-vt for $target ==="
	zig build -Demit-lib-vt -Dsimd=false -Dtarget="$target" --release=fast

	# Map zig target triple to Go-style directory name.
	case "$target" in
	aarch64-macos) dir="darwin-arm64" ;;
	x86_64-macos) dir="darwin-amd64" ;;
	aarch64-linux) dir="linux-arm64" ;;
	x86_64-linux) dir="linux-amd64" ;;
	*)
		echo "WARNING: Unknown target $target, skipping"
		continue
		;;
	esac

	mkdir -p "$OUT_DIR/$dir"
	cp zig-out/lib/libghostty-vt.a "$OUT_DIR/$dir/"
	echo "  -> $OUT_DIR/$dir/libghostty-vt.a ($(du -h "$OUT_DIR/$dir/libghostty-vt.a" | cut -f1))"
done

# Copy headers (same for all platforms).
echo ""
echo "=== Copying headers ==="
mkdir -p "$OUT_DIR/include"
rm -rf "$OUT_DIR/include/ghostty"
cp -r zig-out/include/ghostty "$OUT_DIR/include/"
echo "  -> $OUT_DIR/include/ghostty/"

echo ""
echo "Done. Libraries and headers in $OUT_DIR"
echo "Ghostty commit: $(git rev-parse HEAD)"
