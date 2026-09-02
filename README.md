# SHDome

SHDome 是一个面向 Linux 服务器的模块化管理工具。当前正式版本为 [`v0.1.7`](https://github.com/xuchunlei520/shdome/releases/tag/v0.1.7)，优先提供多应用安装、更新、卸载、独立端口、域名反向代理、HTTPS 证书和访问模式管理。

默认安装后通过“服务器 IP + 独立宿主机端口”访问应用；添加域名后由共享 Nginx 提供 HTTPS，并默认切换为仅域名访问。后续网站、系统、网络和集群功能以独立模块加入，不改变现有应用命令。

## 快速安装

在 Ubuntu、Debian、Rocky Linux、AlmaLinux 或 Alpine Linux 的 amd64/arm64 服务器上执行：

```bash
bash <(curl -fsSL https://k.flowread.cc)
```

Cloudflare 只返回固定版本引导器；安装器从 GitHub Release 下载归档、校验 SHA-256、原子切换版本并安装 `/usr/local/bin/k`。安装完成后直接进入交互菜单。

以后执行：

```bash
k
```

主菜单：

```text
SHDome 服务器管理工具
--------------------------------
1. 应用市场
2. 应用运行环境
3. SHDome 设置
00. 更新 SHDome
0. 退出
--------------------------------
```

## 应用市场

应用市场显示序号、名称、版本、状态和说明。直接输入列表序号或应用名称进入统一操作菜单；不再提供安装、搜索和分类交互子菜单。

```text
1. 安装              2. 更新            3. 卸载
--------------------------------
5. 添加域名访问      6. 删除域名访问
7. 允许IP+端口访问   8. 阻止IP+端口访问
--------------------------------
0. 返回上一级选单
```

`uptime-kuma` 这类内部应用 ID 不用于交互选择，只用于稳定的 CLI 和自动化接口：

```bash
k app list
k app install uptime-kuma
k app status uptime-kuma --json
k app domain uptime-kuma --domain status.example.com --access domain-only --yes
k app access uptime-kuma direct --yes
```

当前目录包含 Cloudreve、Gitea、青龙面板、Uptime Kuma 和禅道。

## 开发运行

```bash
sudo bash src/shdome.sh
sudo bash src/shdome.sh app list
sudo bash src/shdome.sh app install uptime-kuma
```

可通过环境变量把运行数据放到测试目录：

```bash
SHDOME_ROOT=/tmp/shdome-dev bash src/shdome.sh app list
```

正式安装后，普通 sudoer 执行 `k` 或管理命令时会自动提权；`k version` 和 `k help` 等只读命令不会请求提权。应用状态、生成凭据和 Compose 文件保持仅 root 可读。

## 项目结构

- `src/core/`：终端、配置、日志、锁、状态、模块发现、菜单注册和命令路由。
- `src/modules/app_market/`：应用目录、Docker、端口、生命周期、网关、证书和备份。
- `src/modules/<module_id>/module.sh`：业务模块唯一入口，发布包自动发现并激活。
- `catalog/`：声明式 JSON Manifest，不执行远程应用脚本。
- `bootstrap/`：一行安装入口和 Cloudflare Worker。
- `scripts/`：可重复发布包构建脚本。
- `tests/`：单元、CLI、状态、发布和真实 Docker 集成测试。

## 验证状态

项目已通过 ShellCheck、Python/Node 单元测试、Docker 集成测试，以及 5 个发行版 × 2 个架构的 GitHub Actions 矩阵。`v0.1.6` 已在公网 Ubuntu VPS 完成短命令升级、真实 TTY、HTTPS 和 `direct/domain_only` 切换验收。

## 文档

- [使用文档](./使用文档.md)
- [功能文档](./功能文档.md)
- [开发文档](./开发文档.md)
- [发布与 Cloudflare 部署](./docs/发布与Cloudflare部署.md)
- [实现验收矩阵](./docs/实现验收矩阵.md)

当前阶段只在主菜单展示已经完成的应用市场能力。规划中的网站、系统、网络、安全、测试和集群模块在实现前不会注册菜单或返回虚假成功。
