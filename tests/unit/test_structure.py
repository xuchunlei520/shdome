import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class StructureTests(unittest.TestCase):
    def test_reference_project_is_not_nested(self):
        self.assertEqual(ROOT.name, "shdome")

    def test_core_does_not_know_future_commands(self):
        router = (ROOT / "src/core/router.sh").read_text(encoding="utf-8")
        for command in ("web", "system", "network", "cluster"):
            self.assertNotIn(f"command_register {command}", router)
        self.assertNotIn("k app", router)

    def test_module_registers_current_menu(self):
        module = (ROOT / "src/modules/app_market/module.sh").read_text(encoding="utf-8")
        expected = {
            'menu_register 1 "应用市场"',
            'menu_register 2 "应用运行环境"',
        }
        for line in expected:
            self.assertIn(line, module)
        self.assertNotIn('menu_register 2 "已安装应用"', module)
        self.assertNotIn('menu_register 3 "SHDome 设置"', module)
        self.assertIn(
            'menu_register 3 "SHDome 设置"',
            (ROOT / "src/core/router.sh").read_text(encoding="utf-8"),
        )

    def test_market_uses_single_app_action_entry_without_id_column(self):
        catalog = (ROOT / "src/modules/app_market/catalog.sh").read_text(encoding="utf-8")
        menu = (ROOT / "src/modules/app_market/menu.sh").read_text(encoding="utf-8")
        self.assertIn("catalog_resolve_selector", catalog)
        self.assertIn("'序号' '名称' '版本' '状态' '说明'", catalog)
        self.assertNotIn("'应用 ID' '名称' '版本' '状态'", catalog)
        self.assertIn("输入序号或应用名称", menu)
        self.assertNotIn('"${selector,,}" == "${app_id,,}"', catalog)
        for removed_entry in ("i. 安装应用", "s. 搜索应用", "c. 按分类浏览"):
            self.assertNotIn(removed_entry, menu)
        for action in (
            "1. 安装", "2. 更新", "3. 卸载", "5. 添加域名访问",
            "6. 删除域名访问", "7. 允许IP+端口访问", "8. 阻止IP+端口访问",
            "0. 返回上一级选单",
        ):
            self.assertIn(action, menu)
        self.assertIn('app_domain "$app_id" --configure --access domain-only', menu)
        self.assertNotIn("installed_apps_menu()", menu)

    def test_entrypoint_discovers_business_modules(self):
        entrypoint = (ROOT / "src/shdome.sh").read_text(encoding="utf-8")
        self.assertIn("modules_load", entrypoint)
        self.assertIn("modules_activate", entrypoint)
        self.assertNotIn("modules/app_market/manifest.sh", entrypoint)
        self.assertIn(
            "module_register app_market app_market_register",
            (ROOT / "src/modules/app_market/module.sh").read_text(encoding="utf-8"),
        )
        self.assertIn(
            "help_register app_market_help",
            (ROOT / "src/modules/app_market/module.sh").read_text(encoding="utf-8"),
        )

    def test_future_modules_are_not_loadable_placeholders(self):
        self.assertFalse((ROOT / "src/modules/future/module.sh").exists())

    def test_bootstrap_preserves_arguments_and_tty(self):
        installer = (ROOT / "bootstrap/install.sh").read_text(encoding="utf-8")
        self.assertIn('exec "$SCRIPT_PATH" "$@"', installer)
        self.assertNotIn("</dev/null", installer)
        self.assertIn("bootstrap_auto_elevate \"$@\"", installer)
        self.assertIn("exec sudo -H -- env", installer)

    def test_management_entry_auto_elevates_without_relaxing_state_permissions(self):
        entrypoint = (ROOT / "src/shdome.sh").read_text(encoding="utf-8")
        config = (ROOT / "src/core/config.sh").read_text(encoding="utf-8")
        state = (ROOT / "src/core/state.sh").read_text(encoding="utf-8")
        self.assertIn('shdome_auto_elevate "$@"', entrypoint)
        self.assertIn('exec sudo -H -- "$SHDOME_SOURCE_DIR/shdome.sh" "$@"', config)
        self.assertIn("state_storage_require_readable", state)

    def test_release_builder_only_copies_tracked_files(self):
        builder = (ROOT / "scripts/build-release.sh").read_text(encoding="utf-8")
        self.assertIn('git -c "safe.directory=$PROJECT_DIR" -C "$PROJECT_DIR" ls-files -z', builder)
        self.assertNotIn('cp -a "$PROJECT_DIR/src"', builder)
        self.assertIn('find "$PACKAGE_ROOT" -type f -exec chmod 644 {} +', builder)


if __name__ == "__main__":
    unittest.main()
