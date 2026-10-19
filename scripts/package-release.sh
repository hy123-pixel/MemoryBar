#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="$(tr -d '\r\n' < "$ROOT_DIR/VERSION")"
APP_DIR="$ROOT_DIR/build/MemoryBar.app"
DIST_DIR="$ROOT_DIR/dist"
ARCHIVE="$DIST_DIR/MemoryBar-$VERSION-macOS-universal.zip"
TEMP_ARCHIVE="$ARCHIVE.tmp"

if [ -z "$VERSION" ]; then
    echo "VERSION is empty" >&2
    exit 1
fi

"$ROOT_DIR/scripts/build-app.sh"
mkdir -p "$DIST_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$TEMP_ARCHIVE"
mv "$TEMP_ARCHIVE" "$ARCHIVE"
ARCHIVE_NAME="$(basename "$ARCHIVE")"
(cd "$DIST_DIR" && shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256")

printf 'Packaged %s\n' "$ARCHIVE"
cat "$ARCHIVE.sha256"
