"""用真实文件检查发布门禁，坏可选变体也必须拒绝，不能仅靠消费编译。"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

SCRIPT = Path(__file__).with_name("check-maven.py").resolve()
ALGORITHMS = ("md5", "sha1", "sha256", "sha512")
GROUP = "com.github.gycrosskit.fixture"
VERSION = "0.1.0"


class PublicationGate(unittest.TestCase):
    def setUp(self):
        build = SCRIPT.parents[1] / "build/checker-tests"
        build.mkdir(parents=True, exist_ok=True)
        self.temp = TemporaryDirectory(dir=build)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.shared = self.root / "fixture-core" / VERSION / f"fixture-core-{VERSION}.module"
        self.native = self.root / "fixture-core-iosarm64" / VERSION / f"fixture-core-iosarm64-{VERSION}.module"
        for module in (self.shared, self.native):
            module.parent.mkdir(parents=True)
            pom = f'''<project xmlns="http://maven.apache.org/POM/4.0.0"><groupId>{GROUP}</groupId><artifactId>{module.parent.parent.name}</artifactId><version>{VERSION}</version><licenses><license><name>Apache License, Version 2.0</name><url>https://www.apache.org/licenses/LICENSE-2.0.txt</url><distribution>repo</distribution></license></licenses></project>'''
            self.write(module.with_suffix(".pom"), pom.encode())
        artifact = self.shared.parent / "fixture.aar"
        self.write(artifact, b"test artifact")
        files = [{"url": artifact.name, "size": artifact.stat().st_size,
                  **{name: hashlib.new(name, artifact.read_bytes()).hexdigest() for name in ALGORITHMS}}]
        self.save(self.shared, [{"name": "androidRuntime", "files": files}, {
            "name": "iosArm64ApiElements-published", "available-at": {
                "url": "../../fixture-core-iosarm64/0.1.0/fixture-core-iosarm64-0.1.0.module",
                "group": GROUP, "module": "fixture-core-iosarm64", "version": VERSION}}])
        self.save(self.native, [{"name": "iosArm64ApiElements-published", "attributes": {"org.jetbrains.kotlin.native.target": "ios_arm64"}}])

    def write(self, path, content):
        path.write_bytes(content)
        for algorithm in ALGORITHMS:
            path.with_name(path.name + "." + algorithm).write_text(hashlib.new(algorithm, content).hexdigest())

    def save(self, path, variants):
        self.write(path, json.dumps({"component": {"group": GROUP, "module": path.parent.parent.name,
            "version": VERSION}, "variants": variants}).encode())

    def check(self):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.root), GROUP, VERSION,
            "fixture-core", "ios_arm64", "fixture-core,fixture-core-iosarm64"], capture_output=True, text=True)

    def reject(self):
        result = self.check()
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_complete_publication(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_metadata_sidecar(self):
        self.shared.with_name(self.shared.name + ".sha512").unlink()
        self.reject()

    def test_missing_artifact_sidecar(self):
        (self.shared.parent / "fixture.aar.sha1").unlink()
        self.reject()

    def test_missing_pom_sidecar(self):
        self.shared.with_suffix(".pom.md5").unlink()
        self.reject()

    def test_bad_non_sha256_variant_hash(self):
        data = json.loads(self.shared.read_text())
        data["variants"][0]["files"][0]["sha512"] = "incorrect"
        self.write(self.shared, json.dumps(data).encode())
        self.reject()

    def test_missing_declared_hash(self):
        data = json.loads(self.shared.read_text())
        del data["variants"][0]["files"][0]["sha512"]
        self.write(self.shared, json.dumps(data).encode())
        self.reject()

    def test_corrupt_bytes_with_recomputed_sidecars(self):
        self.write(self.shared.parent / "fixture.aar", b"corrupted")
        self.reject()

    def test_foreign_redirect_identity(self):
        data = json.loads(self.shared.read_text())
        data["variants"][1]["available-at"]["group"] = "foreign.group"
        self.write(self.shared, json.dumps(data).encode())
        self.reject()

    def test_wrong_pom_identity(self):
        pom = self.shared.with_suffix(".pom")
        self.write(pom, pom.read_bytes().replace(GROUP.encode(), b"foreign.group"))
        self.reject()

    def test_redirect_needs_same_variant(self):
        self.save(self.native, [{"name": "anotherApi", "attributes": {"org.jetbrains.kotlin.native.target": "ios_arm64"}}])
        self.reject()

    def test_unexpected_publication(self):
        extra = self.root / "unexpected" / VERSION / "unexpected-0.1.0.module"
        extra.parent.mkdir(parents=True)
        self.write(extra.with_suffix(".pom"), self.shared.with_suffix(".pom").read_bytes().replace(b"fixture-core", b"unexpected"))
        self.save(extra, [])
        self.reject()

    def test_source_variant_not_allowed_after_normalization(self):
        data = json.loads(self.shared.read_text())
        data["variants"].append({"name": "metadataSourcesElements"})
        self.write(self.shared, json.dumps(data).encode())
        self.reject()

    def test_missing_license(self):
        pom = self.shared.with_suffix(".pom")
        self.write(pom, pom.read_bytes().replace(b"<licenses>", b"<oldLicenses>").replace(b"</licenses>", b"</oldLicenses>"))
        self.reject()


if __name__ == "__main__":
    unittest.main()
