# 发布与 Cloudflare 引导器

Cloudflare 只提供短域名和小型引导脚本，应用程序发布包仍保存在 GitHub Releases。

## 1. 构建固定版本

在 Linux CI 或开发机执行：

```bash
bash scripts/build-release.sh v0.1.0
```

正式仓库推荐推送符合 `vX.Y.Z` 的 Git tag。`.github/workflows/release.yml` 会先调用完整测试工作流，只有所有测试通过才构建并创建 GitHub Release；已存在的 Release 不会被覆盖。也可以从 Actions 手动触发，但输入的版本必须是已存在且指向当前提交的 tag。

上传以下两个文件到同一个 GitHub Release：

```text
dist/shdome-v0.1.0.tar.gz
dist/shdome-v0.1.0.tar.gz.sha256
```

## 2. 固定安装器 Commit

取得包含 `bootstrap/install.sh` 的 40 位 Git commit。Worker 不允许使用 `main` 或分支名作为安装器地址，避免入口内容在未经审核时变化。

## 3. 配置 Worker

复制 `bootstrap/wrangler.toml.example` 为 `bootstrap/wrangler.toml`，填写：

- `SHDOME_RELEASE_VERSION`：例如 `v0.1.0`。
- `SHDOME_RELEASE_URL`：GitHub Release 中的压缩包地址。
- `SHDOME_RELEASE_SHA256`：构建产生的 64 位摘要。
- `SHDOME_INSTALLER_URL`：固定到 40 位 Commit 的 `raw.githubusercontent.com` 地址。

部署 Worker 后，把短域名（当前生产入口为 `k.flowread.cc`）绑定到该 Worker。根路径返回 `text/plain` Bash，引导器错误时也返回可安全退出的 Bash，不返回 HTML 安装页。

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
