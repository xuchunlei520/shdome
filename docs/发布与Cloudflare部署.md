# 发布与 Cloudflare 引导器

Cloudflare 只提供短域名和小型引导脚本，应用程序发布包仍保存在 GitHub Releases。

当前生产版本为 `v0.1.8`，生产入口为 `https://k.flowread.cc`。以下版本号用于说明当前已验证流程；发布下一版本时应整体替换为新的 `vX.Y.Z`。

当前生产快照：

| 项目 | 值 |
|---|---|
| GitHub Release | `v0.1.8` |
| 发布 Commit | `7d5717770f5111dbf1571d95012fc3d6f0b85ed9` |
| 归档 SHA-256 | `ffd5ea2de49cb950887917b137f96f15396c8b204b17c13833731350ae5675ab` |
| Worker 域名 | `https://k.flowread.cc` |

## 1. 构建固定版本

在 Git 工作区内的 Linux CI 或开发机执行（构建环境需要 Git）：

```bash
bash scripts/build-release.sh v0.1.8
```

正式仓库推荐推送符合 `vX.Y.Z` 的 Git tag。`.github/workflows/release.yml` 会先调用完整测试工作流，只有所有测试通过才构建并创建 GitHub Release；已存在的 Release 不会被覆盖。也可以从 Actions 手动触发，但输入的版本必须是已存在且指向当前提交的 tag。

上传以下两个文件到同一个 GitHub Release：

```text
dist/shdome-v0.1.8.tar.gz
dist/shdome-v0.1.8.tar.gz.sha256
```

## 2. 固定安装器 Commit

取得包含 `bootstrap/install.sh` 的 40 位 Git commit。Worker 不允许使用 `main` 或分支名作为安装器地址，避免入口内容在未经审核时变化。

## 3. 配置 Worker

复制 `bootstrap/wrangler.toml.example` 为 `bootstrap/wrangler.toml`，填写：

- `SHDOME_RELEASE_VERSION`：例如 `v0.1.8`。
- `SHDOME_RELEASE_URL`：GitHub Release 中的压缩包地址。
- `SHDOME_RELEASE_SHA256`：构建产生的 64 位摘要。
- `SHDOME_INSTALLER_URL`：固定到 40 位 Commit 的 `raw.githubusercontent.com` 地址。

部署 Worker 后，把短域名（当前生产入口为 `k.flowread.cc`）绑定到该 Worker。根路径返回 `text/plain` Bash，引导器错误时也返回可安全退出的 Bash，不返回 HTML 安装页。

部署命令：

```bash
npx --yes wrangler deploy --config bootstrap/wrangler.toml
```

`bootstrap/wrangler.toml` 包含真实账户和发布参数，不进入 Git；仓库只提交 `bootstrap/wrangler.toml.example`。

部署后至少验证：

```bash
curl -fsSL https://k.flowread.cc | grep 'v0.1.8'
curl -sS -o /dev/null -w '%{http_code}\n' https://k.flowread.cc
curl -sS -o /dev/null -w '%{http_code}\n' https://k.flowread.cc/missing
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://k.flowread.cc
```

预期依次包含当前版本，并返回 `200`、`404`、`405`。

## 4. 安装链路

```text
bash <(curl -fsSL https://k.flowread.cc)
→ Worker 返回固定版本参数和小型下载器
→ 下载固定 Commit 的 install.sh
→ 下载 GitHub Release 压缩包
→ 校验 SHA-256
→ 原子切换 /opt/shdome/current
→ 创建 /usr/local/bin/k
→ exec /usr/local/bin/k "$@"
```

Worker 不托管 Docker 镜像、应用数据、Nginx 配置或用户证书。
