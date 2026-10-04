"""检查实际发布文件与 Gradle 变体引用，避免本机源码编译掩盖损坏的 Maven 产物。"""
import hashlib
import json
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

if len(sys.argv) != 6:
    raise SystemExit("Usage: check-maven.py repository group version modules_csv native_targets_csv")
repository = Path(sys.argv[1]).resolve()
expected_group = sys.argv[2]
expected_version = sys.argv[3]
expected_modules = set(sys.argv[4].split(","))
expected_targets = set(sys.argv[5].split(","))

def resolve_artifact(path):
    # Maven SNAPSHOT 元数据使用逻辑版本，磁盘文件使用时间戳版本。
    if not path.parent.name.endswith("-SNAPSHOT"):
        return path
    metadata = ET.parse(path.parent / "maven-metadata.xml").getroot()
    artifact_id = metadata.findtext("artifactId")
    version = metadata.findtext("version")
    suffix = path.name.removeprefix(f"{artifact_id}-{version}")
    for snapshot in metadata.findall("./versioning/snapshotVersions/snapshotVersion"):
        classifier = snapshot.findtext("classifier")
        extension = snapshot.findtext("extension")
        expected_suffix = (f"-{classifier}" if classifier else "") + f".{extension}"
        if suffix == expected_suffix:
            return path.with_name(f"{artifact_id}-{snapshot.findtext('value')}{suffix}")
    raise AssertionError(f"No current snapshot artifact: {path}")


modules = []
for path in repository.rglob("*.module"):
    if path.parent.name.endswith("-SNAPSHOT"):
        logical = path.parent / f"{path.parent.parent.name}-{path.parent.name}.module"
        if path != resolve_artifact(logical):
            continue
    modules.append(path)
assert modules, "Maven staging repository is empty"
platforms = set()
coordinates = {}
for module in modules:
    for algorithm in ("md5", "sha1", "sha256", "sha512"):
        checksum = module.with_name(module.name + "." + algorithm)
        if checksum.exists():
            assert checksum.read_text().strip() == hashlib.new(algorithm, module.read_bytes()).hexdigest(), checksum
    data = json.loads(module.read_text())
    component = data["component"]
    assert component["group"] == expected_group, component
    assert component["version"] == expected_version, component
    coordinates.setdefault(component["module"], set()).add(component["version"])
    if "url" in component:
        assert resolve_artifact((module.parent / component["url"]).resolve()).is_file(), component
    for variant in data["variants"]:
        target = variant.get("attributes", {}).get("org.jetbrains.kotlin.native.target")
        if target:
            platforms.add(target)
        if "available-at" in variant:
            redirect = variant["available-at"]
            assert resolve_artifact((module.parent / redirect["url"]).resolve()).is_file(), redirect
        for entry in variant.get("files", []):
            artifact = resolve_artifact((module.parent / entry["url"]).resolve())
            assert artifact.is_file(), artifact
            assert artifact.stat().st_size == entry["size"], artifact
            for algorithm in ("md5", "sha1", "sha256", "sha512"):
                if algorithm in entry:
                    assert hashlib.new(algorithm, artifact.read_bytes()).hexdigest() == entry[algorithm], artifact

for module in modules:
    for variant in json.loads(module.read_text())["variants"]:
        for dependency in variant.get("dependencies", []):
            if dependency["module"] in coordinates:
                assert dependency["group"] == expected_group, dependency
                assert dependency["version"]["requires"] in coordinates[dependency["module"]], dependency

assert expected_targets <= platforms, platforms
assert list(repository.rglob("*.aar")), "Android AAR is missing"
assert expected_modules <= coordinates.keys(), coordinates
for algorithm in ("md5", "sha1", "sha256", "sha512"):
    for checksum in repository.rglob("*." + algorithm):
        artifact = checksum.with_name(checksum.name[:-(len(algorithm) + 1)])
        assert artifact.is_file(), artifact
        assert checksum.read_text().strip() == hashlib.new(algorithm, artifact.read_bytes()).hexdigest(), checksum
print(f"Maven metadata: {len(modules)} modules; artifact hashes, project dependencies and platform variants passed")
