#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="v0.0.0-test"
ARCHIVE="$PROJECT_DIR/dist/shdome-$VERSION.tar.gz"
TEST_ROOT="$(mktemp -d /tmp/shdome-release-test.XXXXXX)"
UNTRACKED_RELEASE_FIXTURE="$(mktemp "$PROJECT_DIR/bootstrap/.release-secret.XXXXXX")"
trap 'rm -f -- "$UNTRACKED_RELEASE_FIXTURE"; rm -rf -- "$TEST_ROOT"' EXIT
printf 'must-not-be-packaged\n' >"$UNTRACKED_RELEASE_FIXTURE"

bash "$PROJECT_DIR/scripts/build-release.sh" "$VERSION" >/dev/null
[[ -s "$ARCHIVE" && -s "$ARCHIVE.sha256" ]]
read -r checksum_name checksum_extra < <(awk '{print $2, $3}' "$ARCHIVE.sha256")
[[ "$checksum_name" == "$(basename "$ARCHIVE")" && -z "$checksum_extra" ]]
[[ "$checksum_name" != */* ]]
(cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE").sha256") >/dev/null
if tar -tzf "$ARCHIVE" | grep -Eq '/bootstrap/(\.wrangler/|wrangler\.toml$|\.release-secret\.)'; then
    printf '发布包包含未跟踪的本地配置或临时文件\n' >&2
    exit 1
fi
(
    export SHDOME_INSTALLER_LIBRARY_ONLY=1
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/bootstrap/install.sh"
    bootstrap_archive_validate "$ARCHIVE" "$VERSION"
)
tar -xzf "$ARCHIVE" -C "$TEST_ROOT"
PACKAGE_ROOT="$TEST_ROOT/shdome-$VERSION"

grep -qx 'SHDOME_VERSION="0.0.0-test"' "$PACKAGE_ROOT/src/core/config.sh"
grep -Fqx "    : \"\${SHDOME_RELEASE_VERSION:=v0.0.0-test}\"" "$PACKAGE_ROOT/src/core/config.sh"
bash -n "$PACKAGE_ROOT/src/shdome.sh"
[[ -x "$PACKAGE_ROOT/bin/k" && -x "$PACKAGE_ROOT/bootstrap/install.sh" ]]
[[ "$(stat -c '%a' "$PACKAGE_ROOT/README.md")" == "644" ]]
[[ -f "$PACKAGE_ROOT/docs/极简应用市场设计.md" ]]
[[ -f "$PACKAGE_ROOT/docs/自动镜像源设计.md" ]]
[[ -f "$PACKAGE_ROOT/src/modules/app_market/image_source.sh" ]]
[[ "$(stat -c '%a' "$PACKAGE_ROOT/bin/k")" == "755" ]]
if find "$PACKAGE_ROOT" -type f -perm /022 -print -quit | grep -q .; then
    printf '发布包包含可被组或其他用户写入的文件\n' >&2
    exit 1
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    fake_bin="$TEST_ROOT/fake-bin"
    mkdir -p "$fake_bin"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "sudo-arg=%s\\n" "$@"' >"$fake_bin/sudo"
    chmod 755 "$fake_bin/sudo"
    installer_elevation_output="$(PATH="$fake_bin:$PATH" \
        SHDOME_RELEASE_VERSION=v9.9.9 \
        SHDOME_RELEASE_URL=https://github.com/example/shdome/releases/download/v9.9.9/shdome-v9.9.9.tar.gz \
        SHDOME_RELEASE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        SHDOME_NO_LAUNCH=1 \
        bash "$PROJECT_DIR/bootstrap/install.sh" forwarded-argument)"
    grep -q '^sudo-arg=-H$' <<<"$installer_elevation_output"
    grep -q '^sudo-arg=SHDOME_RELEASE_VERSION=v9.9.9$' <<<"$installer_elevation_output"
    grep -q '^sudo-arg=SHDOME_NO_LAUNCH=1$' <<<"$installer_elevation_output"
    grep -q '^sudo-arg=forwarded-argument$' <<<"$installer_elevation_output"
fi

export SHDOME_ROOT="$TEST_ROOT/runtime"
export SHDOME_ALLOW_NON_ROOT=1
version_output="$(bash "$PACKAGE_ROOT/src/shdome.sh" version)"
grep -q '^SHDome 0.0.0-test$' <<<"$version_output"
details_output="$(bash "$PACKAGE_ROOT/src/shdome.sh" app details gitea)"
grep -q '2222/tcp' <<<"$details_output"

if command -v openssl >/dev/null 2>&1; then
    catalog_key="$TEST_ROOT/catalog-private.pem"
    openssl genpkey -algorithm ED25519 -out "$catalog_key" >/dev/null 2>&1
    bash "$PROJECT_DIR/scripts/build-catalog.sh" test-release "$catalog_key" >/dev/null
    [[ -s "$PROJECT_DIR/dist/catalog/catalog-test-release.tar.gz" ]]
    [[ -s "$PROJECT_DIR/dist/catalog/catalog-test-release.tar.gz.sig" ]]
fi

printf 'Release smoke tests passed\n'
