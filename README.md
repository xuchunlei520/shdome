# SHDome

SHDome 是一个面向 Linux 服务器的模块化管理工具。当前版本只优先实现应用市场，默认通过“服务器 IP + 独立宿主机端口”访问应用；域名、Nginx 和证书是安装后的可选增强。后续网站、系统、网络和集群功能以独立模块加入，不改变现有应用命令。

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

## 项目边界

- `src/core/`：终端、配置、日志、锁、状态、模块发现、菜单注册和命令路由。
- `src/modules/app_market/`：应用目录、Docker、端口和应用生命周期。
- `src/modules/<module_id>/module.sh`：业务模块唯一入口；发布包自动发现并激活，无需修改总入口。
- `catalog/`：只包含声明式 JSON Manifest，不执行远程应用脚本。
- `bootstrap/`：一行安装入口和 Cloudflare Worker。
- `scripts/`：构建与校验脚本。
- `tests/`：无需 Docker 的单元测试和需要 Linux/Docker 的冒烟测试。

完整设计和用户命令见 [开发文档](./开发文档.md)、[功能文档](./功能文档.md) 和 [使用文档](./使用文档.md)。

当前实现与剩余外部验收条件见 [实现验收矩阵](./docs/实现验收矩阵.md)。
