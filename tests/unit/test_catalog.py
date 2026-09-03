import json
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class CatalogTests(unittest.TestCase):
    def test_expected_official_catalog_expansion(self):
        ids = {path.stem for path in (ROOT / "catalog").glob("*.json")}
        self.assertEqual(ids, {
            "alist", "cloudreve", "freshrss", "gitea", "qinglong",
            "syncthing", "uptime-kuma", "vaultwarden", "zentao",
        })

    def test_at_least_three_valid_manifests(self):
        manifests = sorted((ROOT / "catalog").glob("*.json"))
        self.assertGreaterEqual(len(manifests), 3)
        seen_ids = set()
        seen_host_ports = set()
        for path in manifests:
            item = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(item["schema"], 2)
            self.assertRegex(item["id"], r"^[a-z0-9][a-z0-9-]{1,62}$")
            self.assertEqual(path.stem, item["id"])
            self.assertNotIn(item["id"], seen_ids)
            seen_ids.add(item["id"])
            for service in item["services"].values():
                self.assertRegex(service["image"], r"^[^:]+:[A-Za-z0-9][A-Za-z0-9._-]+$")
            ports = item["ports"]
            self.assertEqual(sum(bool(port.get("primary")) for port in ports), 1)
            for port in ports:
                self.assertTrue(1 <= port["containerPort"] <= 65535)
                host_key = (port["defaultHostPort"], port.get("protocol", "tcp"))
                self.assertNotIn(host_key, seen_host_ports)
                seen_host_ports.add(host_key)
            self.assertEqual(item["routing"]["defaultAccessMode"], "direct")

    def test_catalog_contains_real_multi_port_app(self):
        manifests = [json.loads(path.read_text(encoding="utf-8")) for path in (ROOT / "catalog").glob("*.json")]
        multi_port_apps = [item for item in manifests if len(item.get("ports", [])) > 1]
        self.assertTrue(multi_port_apps)

    def test_no_mutable_latest_images(self):
        for path in (ROOT / "catalog").glob("*.json"):
            item = json.loads(path.read_text(encoding="utf-8"))
            for service in item["services"].values():
                self.assertFalse(service["image"].endswith(":latest"))

    def test_logical_backup_adapters_reference_declared_file_volumes(self):
        logical_apps = []
        for path in (ROOT / "catalog").glob("*.json"):
            item = json.loads(path.read_text(encoding="utf-8"))
            backup = item.get("backup", {"strategy": "cold-filesystem"})
            self.assertEqual(backup.get("strategy", "cold-filesystem"), "cold-filesystem")
            logical = backup.get("logical")
            if not logical:
                continue
            logical_apps.append(item["id"])
            self.assertEqual(logical["type"], "sqlite")
            service = item["services"][logical["service"]]
            file_sources = {
                volume["source"]
                for volume in service.get("volumes", [])
                if volume.get("type", "directory") == "file"
            }
            self.assertIn(logical["source"], file_sources)
            self.assertRegex(logical["output"], r"^[A-Za-z0-9][A-Za-z0-9._-]*\.sql$")
        self.assertIn("cloudreve", logical_apps)

    def test_three_fixture_apps_share_container_port_only(self):
        fixtures = [json.loads(path.read_text(encoding="utf-8")) for path in (ROOT / "tests/fixtures/multi-app").glob("*.json")]
        self.assertEqual(len(fixtures), 3)
        self.assertEqual({next(port["containerPort"] for port in item["ports"] if port["primary"]) for item in fixtures}, {80})
        self.assertEqual(len({next(port["defaultHostPort"] for port in item["ports"] if port["primary"]) for item in fixtures}), 3)

    def test_database_redis_and_app_fixture(self):
        path = ROOT / "tests" / "fixtures" / "multi-container" / "demo-stack.json"
        item = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(set(item["services"]), {"app", "database", "redis"})
        self.assertEqual(item["services"]["app"]["dependsOn"], ["database", "redis"])
        self.assertEqual({port["service"] for port in item["ports"]}, {"app"})
        self.assertEqual(
            item["services"]["app"]["secretEnvironment"]["DATABASE_PASSWORD"],
            item["services"]["database"]["secretEnvironment"]["POSTGRES_PASSWORD"],
        )


if __name__ == "__main__":
    unittest.main()
