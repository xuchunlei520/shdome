#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="${1:-}"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][a-zA-Z0-9._-]+)?$ ]] || {
    printf '用法：%s v1.2.3\n' "$0" >&2
    exit 64
}

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
TEMP_DIR="$(mktemp -d /tmp/shdome-build.XXXXXX)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
PACKAGE_ROOT="$TEMP_DIR/shdome-$VERSION"

mkdir -p "$DIST_DIR" "$PACKAGE_ROOT"
cp -a "$PROJECT_DIR/src" "$PROJECT_DIR/catalog" "$PROJECT_DIR/bin" "$PROJECT_DIR/bootstrap" "$PACKAGE_ROOT/"
cp "$PROJECT_DIR/README.md" "$PROJECT_DIR/开发文档.md" "$PROJECT_DIR/功能文档.md" "$PROJECT_DIR/使用文档.md" "$PACKAGE_ROOT/"
chmod 755 "$PACKAGE_ROOT/bin/k" "$PACKAGE_ROOT/src/shdome.sh" "$PACKAGE_ROOT/bootstrap/install.sh"
sed -i "s/^SHDOME_VERSION=.*/SHDOME_VERSION=\"${VERSION#v}\"/" "$PACKAGE_ROOT/src/core/config.sh"
sed -i "s|^    : \"\${SHDOME_RELEASE_VERSION:=.*}\"$|    : \"\${SHDOME_RELEASE_VERSION:=$VERSION}\"|" "$PACKAGE_ROOT/src/core/config.sh"
find "$PACKAGE_ROOT" -type f -name '*.sh' -exec sed -i 's/\r$//' {} +

archive="$DIST_DIR/shdome-$VERSION.tar.gz"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 2020-01-01' -czf "$archive" -C "$TEMP_DIR" "shdome-$VERSION"
(
    cd "$DIST_DIR"
    sha256sum "$(basename "$archive")" | tee "$(basename "$archive").sha256"
)
