const textHeaders = {
  "content-type": "text/plain; charset=utf-8",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
};

function shellQuote(value) {
  return `'${String(value).replaceAll("'", `'"'"'`)}'`;
}

function errorScript(message) {
  return `#!/usr/bin/env bash\nprintf '%s\\n' ${shellQuote(`[SHDome 引导器错误] ${message}`)} >&2\nexit 1\n`;
}

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
    if (url.protocol === "http:") {
      url.protocol = "https:";
      return Response.redirect(url.toString(), 308);
    }
    if (url.pathname !== "/") {
      return new Response("Not Found\n", {status: 404, headers: textHeaders});
    }
    if (request.method !== "GET") {
      return new Response("Method Not Allowed\n", {status: 405, headers: {...textHeaders, allow: "GET"}});
    }

    const version = env.SHDOME_RELEASE_VERSION || "";
    const archiveUrl = env.SHDOME_RELEASE_URL || "";
    const sha256 = env.SHDOME_RELEASE_SHA256 || "";
    const installerUrl = env.SHDOME_INSTALLER_URL || "";
    if (!/^v\d+\.\d+\.\d+([.-][A-Za-z0-9._-]+)?$/.test(version)) {
      return new Response(errorScript("SHDOME_RELEASE_VERSION 配置错误"), {status: 503, headers: textHeaders});
    }
    if (!/^https:\/\/github\.com\/.+\/releases\/download\/.+/.test(archiveUrl)) {
      return new Response(errorScript("SHDOME_RELEASE_URL 配置错误"), {status: 503, headers: textHeaders});
    }
    if (!/^[a-fA-F0-9]{64}$/.test(sha256)) {
      return new Response(errorScript("SHDOME_RELEASE_SHA256 配置错误"), {status: 503, headers: textHeaders});
    }
    if (!/^https:\/\/raw\.githubusercontent\.com\/.+\/[a-fA-F0-9]{40}\/bootstrap\/install\.sh$/.test(installerUrl)) {
      return new Response(errorScript("SHDOME_INSTALLER_URL 必须固定到 Git commit"), {status: 503, headers: textHeaders});
    }

    const bootstrap = `#!/usr/bin/env bash
set -Eeuo pipefail
export SHDOME_RELEASE_VERSION=${shellQuote(version)}
export SHDOME_RELEASE_URL=${shellQuote(archiveUrl)}
export SHDOME_RELEASE_SHA256=${shellQuote(sha256.toLowerCase())}
tmp_file="$(mktemp /tmp/shdome-bootstrap.XXXXXX)"
cleanup() { rm -f -- "$tmp_file"; }
trap cleanup EXIT INT TERM
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$tmp_file" ${shellQuote(installerUrl)}
[[ -s "$tmp_file" ]] || { printf '%s\\n' '[SHDome] 安装器下载为空' >&2; exit 1; }
head -n 1 "$tmp_file" | grep -q '^#!/usr/bin/env bash$' || { printf '%s\\n' '[SHDome] 安装器格式错误' >&2; exit 1; }
chmod 700 "$tmp_file"
SCRIPT_PATH="$tmp_file"
exec "$SCRIPT_PATH" "$@"
`;
      return new Response(bootstrap, {status: 200, headers: textHeaders});
    } catch (error) {
      return new Response(errorScript("引导器内部错误，请稍后重试"), {status: 500, headers: textHeaders});
    }
  },
};
