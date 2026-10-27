"""使用真实 ZIP/metadata 文件验证发布裁剪，不需要 Gradle 或厂商 SDK。"""
import hashlib
import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
import subprocess
import sys
import copy
import xml.etree.ElementTree as ET
from zipfile import ZipFile

spec = importlib.util.spec_from_file_location("metadata", Path(__file__).resolve().with_name("jitpack-metadata.py"))
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class PublicationContracts(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.native = self.root / "native.module"
        self.shared = self.root / "shared.module"
        self.resource_name = "iosArm64ResourcesElements-published"
        self.api = {"name": "iosArm64ApiElements-published", "files": [{"url": "main.klib"}]}
        self.resource = {"name": self.resource_name, "files": [{"url": "resources.zip"}]}
        with ZipFile(self.root / "resources.zip", "w") as zipped:
            zipped.writestr("composeResources/", b"")
        self.write(self.native, [self.api, self.resource])
        self.write(self.shared, [{"name": self.resource_name, "available-at": {"url": "native.module"}}, {"name": "metadataApiElements"}, {"name": "metadataSourcesElements"}])

    def write(self, path, variants):
        path.write_text(json.dumps({"variants": variants}))

    def variants(self, path):
        return json.loads(path.read_text())["variants"]

    def test_empty_resource_and_forwarding_removed_api_preserved(self):
        self.assertEqual(metadata.normalize([self.native, self.shared]), 2)
        self.assertEqual(self.variants(self.native), [self.api])
        self.assertEqual(self.variants(self.shared), [{"name": "metadataApiElements"}])
        self.assertEqual(metadata.normalize([self.native, self.shared]), 0)

    def test_nonempty_resource_fails_before_any_write(self):
        before = {path: path.read_bytes() for path in (self.shared, self.native)}
        with ZipFile(self.root / "resources.zip", "a") as zipped:
            zipped.writestr("composeResources/image.png", b"image")
        with self.assertRaisesRegex(ValueError, "Nonempty resources"):
            metadata.normalize([self.shared, self.native])
        self.assertEqual(before, {path: path.read_bytes() for path in before})

    def test_zero_byte_real_file_also_requires_resource_publication(self):
        with ZipFile(self.root / "resources.zip", "a") as zipped:
            zipped.writestr("composeResources/empty.txt", b"")
        with self.assertRaisesRegex(ValueError, "Nonempty resources"):
            metadata.normalize([self.native, self.shared])

    def test_missing_resource_target_fails_without_write(self):
        before = self.shared.read_bytes()
        with self.assertRaisesRegex(ValueError, "Missing resource metadata"):
            metadata.normalize([self.shared])
        self.assertEqual(self.shared.read_bytes(), before)

    def test_root_sources_exact_and_classified_variants_only(self):
        keep = {"name": "customSourcesElements"}
        self.write(self.native, [self.api, keep, {"name": "iosArm64SourcesElements-published"}, {"name": "iosArm64MetadataElements-published"}])
        metadata.normalize([self.native])
        self.assertEqual(self.variants(self.native), [self.api, keep])

    def test_empty_repository_fails(self):
        with TemporaryDirectory() as empty:
            result = subprocess.run([sys.executable, str(spec.origin), empty], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("No Maven module metadata", result.stderr)

    def test_all_existing_metadata_checksums_refreshed(self):
        for algorithm in ("sha1", "sha256", "sha512", "md5"):
            self.native.with_suffix(".module." + algorithm).write_text("old")
        metadata.normalize([self.native, self.shared])
        for algorithm in ("sha1", "sha256", "sha512", "md5"):
            self.assertEqual(self.native.with_suffix(".module." + algorithm).read_text(), hashlib.new(algorithm, self.native.read_bytes()).hexdigest())


class ImageThumbnailPublication(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "com/github/gycrosskit/media"
        self.version = "1.0.2"
        self.directory = self.root / "media-core-ohosarm64" / self.version
        self.directory.mkdir(parents=True)
        self.module = self.directory / f"media-core-ohosarm64-{self.version}.module"
        self.group = "com.github.gycrosskit.media"
        self.unique = self.group + ":media-core-cinterop-imageThumbnail"
        self.payloads = []
        entries = []
        for suffix, manifest in (("", f"unique_name={self.group}:media-core\ndepends=stdlib {self.unique}\n"),
                                 ("-cinterop-imageThumbnail", f"unique_name={self.unique}\ndepends=stdlib\ninterop=true\n")):
            path = self.directory / f"media-core-ohosarm64-{self.version}{suffix}.klib"
            with ZipFile(path, "w") as archive:
                archive.writestr("default/manifest", manifest + "native_targets=ohos_arm64\ncompiler_version=2.2.21-1.0.0\n")
            payload = path.read_bytes()
            self.payloads.append(payload)
            entry = {"name": path.name, "url": path.name, "size": len(payload)}
            for algorithm in metadata.ALGORITHMS:
                entry[algorithm] = hashlib.new(algorithm, payload).hexdigest()
                path.with_name(path.name + "." + algorithm).write_text(entry[algorithm])
            entries.append(entry)
        self.stdlib = {"group": "org.jetbrains.kotlin", "module": "kotlin-stdlib", "version": {"requires": "2.2.21-1.0.0"}}
        self.data = {"formatVersion": "1.1", "component": {"group": self.group, "module": "media-core", "version": self.version},
                     "variants": [{"name": "ohosArm64ApiElements-published", "attributes": {
                         "artifactType": "org.jetbrains.kotlin.klib", "org.jetbrains.kotlin.native.target": "ohos_arm64",
                         "org.jetbrains.kotlin.platform.type": "native", "org.gradle.usage": "kotlin-api"},
                         "files": entries, "dependencies": [self.stdlib, {"group": "org.jetbrains.kotlinx", "module": "kotlinx-coroutines-core", "version": {"requires": "1.10.2-1.0.0"}}]}]}
        self.save()
        self.module.with_suffix(".pom").write_text(f'''<project xmlns="http://maven.apache.org/POM/4.0.0">
<modelVersion>4.0.0</modelVersion><groupId>{self.group}</groupId><artifactId>media-core-ohosarm64</artifactId><version>{self.version}</version><packaging>klib</packaging>
<licenses><license><name>Apache License, Version 2.0</name><url>https://www.apache.org/licenses/LICENSE-2.0.txt</url><distribution>repo</distribution></license></licenses>
<dependencies><dependency><groupId>org.jetbrains.kotlin</groupId><artifactId>kotlin-stdlib</artifactId><version>2.2.21-1.0.0</version><scope>compile</scope></dependency></dependencies></project>''')
        self.sidecars(self.module.with_suffix(".pom"))

    def sidecars(self, path):
        for algorithm in metadata.ALGORITHMS:
            path.with_name(path.name + "." + algorithm).write_text(hashlib.new(algorithm, path.read_bytes()).hexdigest())

    def save(self):
        self.module.write_text(json.dumps(self.data))
        self.sidecars(self.module)

    def snapshot(self):
        return {str(path.relative_to(self.root)): path.read_bytes() for path in self.root.rglob("*") if path.is_file()}

    def test_real_cli_moves_exact_bytes_and_preserves_dependency_attributes_and_pom(self):
        # fresh Gradle publication 尚含 sources/commonized metadata，既有规范化仍须保留。
        self.data["variants"].extend([{"name": "ohosArm64SourcesElements-published"},
                                       {"name": "ohosArm64MetadataElements-published"}])
        self.save()
        command = [sys.executable, str(spec.origin), str(self.root)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        native = json.loads(self.module.read_text())["variants"][0]
        target = self.root / "media-cinterop-ohosarm64" / self.version
        module = target / f"media-cinterop-ohosarm64-{self.version}.module"
        interop = json.loads(module.read_text())["variants"][0]
        self.assertEqual([self.data["variants"][0]["files"][0]], native["files"])
        self.assertEqual(self.data["variants"][0]["dependencies"], native["dependencies"][:-1])
        self.assertEqual({"group": self.group, "module": "media-cinterop-ohosarm64", "version": {"requires": self.version}}, native["dependencies"][-1])
        self.assertEqual(self.data["variants"][0]["attributes"], interop["attributes"])
        self.assertEqual([self.stdlib], interop["dependencies"])
        self.assertEqual(self.payloads, [(self.directory / native["files"][0]["url"]).read_bytes(), (target / interop["files"][0]["url"]).read_bytes()])
        self.assertEqual(2, len(list(self.root.rglob("*.klib"))))
        self.assertEqual(interop["files"][0]["name"], interop["files"][0]["url"])
        ns = {"m": "http://maven.apache.org/POM/4.0.0"}
        main_pom = ET.parse(self.module.with_suffix(".pom"))
        self.assertEqual("media-cinterop-ohosarm64", main_pom.findall("m:dependencies/m:dependency", ns)[-1].findtext("m:artifactId", namespaces=ns))
        self.assertEqual("kotlin-stdlib", ET.parse(module.with_suffix(".pom")).findtext("m:dependencies/m:dependency/m:artifactId", namespaces=ns))
        for file in self.root.rglob("*"):
            if file.suffix in (".module", ".pom", ".klib"):
                for algorithm in metadata.ALGORITHMS:
                    self.assertEqual(hashlib.new(algorithm, file.read_bytes()).hexdigest(), file.with_name(file.name + "." + algorithm).read_text())

    def test_corrupt_bytes_metadata_checksum_and_unknown_abi_reject_without_writes(self):
        original = copy.deepcopy(self.data)
        for mutate in (lambda: self.data["variants"][0]["files"][1].update(size=1),
                       lambda: self.data["variants"][0]["files"][0].update(sha512="f" * 128),
                       lambda: self.data["variants"][0]["files"].append(copy.deepcopy(self.data["variants"][0]["files"][0])),
                       lambda: self.data["variants"][0]["attributes"].update({"org.jetbrains.kotlin.native.target": "ios_arm64"})):
            with self.subTest(mutate=mutate):
                self.data = copy.deepcopy(original); mutate(); self.save()
                before = self.snapshot()
                with self.assertRaises(ValueError):
                    metadata.normalize([self.module])
                self.assertEqual(before, self.snapshot())

    def test_wrong_manifest_dependency_and_existing_target_reject_without_writes(self):
        path = self.directory / self.data["variants"][0]["files"][1]["url"]
        original = path.read_bytes()
        with ZipFile(path, "w") as archive:
            archive.writestr("default/manifest", "depends=stdlib\ninterop=true\nunique_name=wrong\nnative_targets=ohos_arm64\ncompiler_version=2.2.21-1.0.0\n")
        entry = self.data["variants"][0]["files"][1]; entry["size"] = path.stat().st_size
        for algorithm in metadata.ALGORITHMS:
            entry[algorithm] = hashlib.new(algorithm, path.read_bytes()).hexdigest()
            path.with_name(path.name + "." + algorithm).write_text(entry[algorithm])
        self.save(); before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "dependency/ABI"):
            metadata.normalize([self.module])
        self.assertEqual(before, self.snapshot())
        path.write_bytes(original)
        entry["size"] = len(original)
        for algorithm in metadata.ALGORITHMS:
            entry[algorithm] = hashlib.new(algorithm, original).hexdigest()
            path.with_name(path.name + "." + algorithm).write_text(entry[algorithm])
        self.save()
        (self.root / "media-cinterop-ohosarm64" / self.version).mkdir(parents=True)
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "already exists"):
            metadata.normalize([self.module])
        self.assertEqual(before, self.snapshot())

    def test_bad_input_sidecars_fail_before_creating_publication(self):
        paths = [self.module, self.module.with_suffix(".pom"),
                 self.directory / self.data["variants"][0]["files"][0]["url"],
                 self.directory / self.data["variants"][0]["files"][1]["url"]]
        for path in paths:
            with self.subTest(path=path.name):
                sidecar = path.with_name(path.name + ".sha256")
                old = sidecar.read_bytes(); sidecar.write_text("0" * 64)
                before = self.snapshot()
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    metadata.normalize([self.module])
                self.assertEqual(before, self.snapshot())
                sidecar.write_bytes(old)

    def test_legacy_101_keeps_two_file_layout(self):
        # 旧冻结归档不按新模块布局重解释。
        self.data["component"]["version"] = "1.0.1"
        self.save()
        before = self.snapshot()
        self.assertEqual(0, metadata.normalize([self.module]))
        self.assertEqual(before, self.snapshot())


if __name__ == "__main__":
    unittest.main()
