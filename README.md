# SHDome

SHDome 是一个面向 Linux 服务器的模块化管理工具。当前正式版本为 [`v0.2.0`](https://github.com/xuchunlei520/shdome/releases/tag/v0.2.0)，优先提供单容器及多容器应用安装、更新、卸载、独立端口、域名反向代理、HTTPS 证书和访问模式管理。

默认安装后通过“服务器 IP + 独立宿主机端口”访问应用；添加域名后由共享 Nginx 提供 HTTPS，并默认切换为仅域名访问。后续网站、系统、网络和集群功能以独立模块加入，不改变现有应用命令。

一个应用可以由主程序、数据库和 Redis 等多个容器组成。SHDome 将它们作为同一个 Compose 项目管理，只有清单声明的主服务端口对外发布；允许 IP+端口访问时，管理页直接显示完整访问地址。

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

应用市场统一显示官方应用和用户自定义应用，并标明来源。未安装应用只需输入序号或名称并确认一次，SHDome 会自动选择可用端口、准备 Docker 和数据目录；已安装应用仍进入统一管理菜单。输入 `A` 可以通过一个固定版本 Docker 镜像添加自定义应用。

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
k app custom add vaultwarden/server:1.32.7
k app custom list
k app catalog status
k env mirror status
k app status uptime-kuma --json
k app domain uptime-kuma --domain status.example.com --access domain-only --yes
k app access uptime-kuma direct --yes
```

当前目录包含 AList、Cloudreve、FreshRSS、Gitea、青龙面板、Syncthing、Uptime Kuma、Vaultwarden 和禅道。

自定义应用保存在 `/opt/shdome/catalog/custom/`，不会随 SHDome 升级被覆盖。镜像没有声明服务端口时，可补充 `--container-port`；需要高级端口设置时使用 `--host-port`。官方目录支持使用可信公钥验签后独立刷新，完整参数和安全边界见[极简应用市场设计](./docs/极简应用市场设计.md)。

应用镜像默认启用自动选源：Docker Hub 正常时优先官方源，连接缓慢或失败时自动尝试可信 HTTPS 镜像源，全部远程来源失败时再使用同名固定版本本地缓存。该流程不增加安装确认、不修改 `/etc/docker/daemon.json`，也不会重启 Docker。管理员可通过 `k env mirror status|test|auto|official|set|reset` 管理策略。

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
- `src/modules/app_market/`：应用目录、自定义应用、目录验签刷新、自动镜像源、Docker、端口、生命周期、网关、证书和备份。
- `src/modules/<module_id>/module.sh`：业务模块唯一入口，发布包自动发现并激活。
- `catalog/`：声明式 JSON Manifest，不执行远程应用脚本。
- `bootstrap/`：一行安装入口和 Cloudflare Worker。
- `scripts/`：可重复发布包构建脚本。
- `tests/`：单元、CLI、状态、发布和真实 Docker 集成测试。

## 验证状态

项目通过 ShellCheck、Python/Node 单元测试、Docker 集成测试，以及 5 个发行版 × 2 个架构的 GitHub Actions 矩阵。`v0.2.0` 的 Schema 2 多容器应用和直连地址展示已通过完整发布 CI，生产入口已固定到对应 Release、SHA-256 和 installer commit；详情见[实现验收矩阵](./docs/实现验收矩阵.md)。

## 文档

- [使用文档](./使用文档.md)
- [功能文档](./功能文档.md)
- [开发文档](./开发文档.md)
- [发布与 Cloudflare 部署](./docs/发布与Cloudflare部署.md)
- [实现验收矩阵](./docs/实现验收矩阵.md)
- [极简应用市场设计](./docs/极简应用市场设计.md)
- [自动镜像源设计](./docs/自动镜像源设计.md)

当前阶段只在主菜单展示已经完成的应用市场能力。规划中的网站、系统、网络、安全、测试和集群模块在实现前不会注册菜单或返回虚假成功。
