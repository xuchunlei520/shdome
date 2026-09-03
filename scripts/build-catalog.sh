#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="${1:-}"
PRIVATE_KEY="${2:-}"
[[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$ && -f "$PRIVATE_KEY" ]] || {
    printf '用法：%s <目录版本> <Ed25519私钥.pem>\n' "$0" >&2
    exit 64
}

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist/catalog"
TEMP_DIR="$(mktemp -d /tmp/shdome-catalog-build.XXXXXX)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
ARCHIVE="$DIST_DIR/catalog-$VERSION.tar.gz"
SIGNATURE="$ARCHIVE.sig"
PUBLIC_KEY="$TEMP_DIR/public.pem"

command -v openssl >/dev/null 2>&1 || { printf '缺少 openssl\n' >&2; exit 69; }
mkdir -p "$DIST_DIR" "$TEMP_DIR/catalog"
while IFS= read -r -d '' manifest; do
    cp -- "$manifest" "$TEMP_DIR/catalog/$(basename "$manifest")"
done < <(find "$PROJECT_DIR/catalog" -maxdepth 1 -type f -name '*.json' -print0 | sort -z)
[[ -n "$(find "$TEMP_DIR/catalog" -type f -name '*.json' -print -quit)" ]] || { printf '应用目录为空\n' >&2; exit 66; }

tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 2020-01-01' \
    -czf "$ARCHIVE" -C "$TEMP_DIR/catalog" .
openssl pkeyutl -sign -inkey "$PRIVATE_KEY" -rawin -in "$ARCHIVE" -out "$SIGNATURE"
openssl pkey -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY" >/dev/null 2>&1
openssl pkeyutl -verify -pubin -inkey "$PUBLIC_KEY" -rawin -in "$ARCHIVE" -sigfile "$SIGNATURE" >/dev/null
sha256sum "$ARCHIVE" >"$ARCHIVE.sha256"
printf '已生成：\n%s\n%s\n' "$ARCHIVE" "$SIGNATURE"
