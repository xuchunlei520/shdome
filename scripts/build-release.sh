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

command -v git >/dev/null 2>&1 || {
    printf '构建发布包需要 git\n' >&2
    exit 69
}
git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    printf '发布包必须从 Git 工作区构建\n' >&2
    exit 69
}

mkdir -p "$DIST_DIR" "$PACKAGE_ROOT"
while IFS= read -r -d '' relative_path; do
    target_path="$PACKAGE_ROOT/$relative_path"
    mkdir -p "$(dirname "$target_path")"
    cp -a -- "$PROJECT_DIR/$relative_path" "$target_path"
done < <(git -C "$PROJECT_DIR" ls-files -z -- \
    src catalog bin bootstrap README.md 开发文档.md 功能文档.md 使用文档.md)

for required_path in bin/k src/shdome.sh bootstrap/install.sh bootstrap/worker.js bootstrap/wrangler.toml.example; do
    [[ -f "$PACKAGE_ROOT/$required_path" ]] || {
        printf '发布包缺少已跟踪文件：%s\n' "$required_path" >&2
        exit 66
    }
done
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
