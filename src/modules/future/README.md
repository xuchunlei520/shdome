# 后续模块接入约定

后续模块建立独立目录，并提供唯一入口 `src/modules/<module_id>/module.sh`。主程序会自动发现该入口；入口负责加载模块内部文件，最后调用：

```bash
module_register <module_id> <register_handler>
```

`register_handler` 再通过 `command_register`、`menu_register` 和 `help_register` 注册命令、菜单及帮助内容，不直接修改 `src/shdome.sh`、核心路由或主菜单。开发中的模块不要提供 `module.sh`，发布包因而不会加载或显示它。

预留菜单编号：

- `10–19`：网站与建站
- `20–29`：系统管理
- `30–39`：网络、内核与安全
- `40–49`：测试与诊断
- `50–59`：工作区、任务与集群

模块成熟前不注册菜单项，也不显示“开发中”占位菜单。
