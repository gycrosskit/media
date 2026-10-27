"""移除 JitPack 无法保持 classifier 的变体，空资源可省略，真实资源必须修复发布。"""
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile


ALGORITHMS = ("sha1", "sha256", "sha512", "md5")


def image_thumbnail_publication(module, data):
    """复用 dynamic-page 的单主 KLIB 坐标，避免 JitPack 合并 classifier URL。"""
    if module.parent.parent.name != "media-core-ohosarm64":
        return None
    group, version = data["component"]["group"], data["component"]["version"]
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?", version)
    if not match or tuple(map(int, match.group(1, 2, 3))) < (1, 0, 2):
        return None
    if group != "com.github.gycrosskit.media" or module.name != f"media-core-ohosarm64-{version}.module":
        raise ValueError("Unexpected Media OHOS publication identity")
    for path in (module, module.with_suffix(".pom")):
        for algorithm in ALGORITHMS:
            sidecar = path.with_name(path.name + "." + algorithm)
            if path.is_symlink() or sidecar.is_symlink() or sidecar.read_text().strip() != hashlib.new(algorithm, path.read_bytes()).hexdigest():
                raise ValueError("Media metadata checksum mismatch")
    variant, = (item for item in data["variants"] if item["name"] == "ohosArm64ApiElements-published")
    if (variant["name"] != "ohosArm64ApiElements-published"
            or variant["attributes"].get("org.jetbrains.kotlin.native.target") != "ohos_arm64"):
        raise ValueError("Unexpected Media OHOS variant")
    main, = (item for item in variant["files"] if item["url"] == f"media-core-ohosarm64-{version}.klib")
    interop, = (item for item in variant["files"] if item["url"] == f"media-core-ohosarm64-{version}-cinterop-imageThumbnail.klib")
    if len(variant["files"]) != 2:
        raise ValueError("Media OHOS must contain exactly the main and imageThumbnail KLIB")
    payloads, manifests = [], []
    for entry in (main, interop):
        source = module.parent / entry["url"]
        if source.is_symlink() or not source.is_file():
            raise ValueError("Media KLIB must be a regular file")
        payload = source.read_bytes()
        if len(payload) != entry["size"] or any(
                hashlib.new(algorithm, payload).hexdigest() != entry[algorithm] for algorithm in ALGORITHMS):
            raise ValueError("Media KLIB size/hash mismatch")
        for algorithm in ALGORITHMS:
            sidecar = source.with_name(source.name + "." + algorithm)
            if sidecar.is_symlink() or sidecar.read_text().strip() != entry[algorithm]:
                raise ValueError("Media KLIB checksum mismatch")
        with ZipFile(source) as library:
            if library.testzip() is not None:
                raise ValueError("Corrupt Media KLIB")
            manifest = dict(line.split("=", 1) for line in library.read("default/manifest").decode().splitlines() if "=" in line)
        payloads.append(payload)
        manifests.append(manifest)
    unique_name = "com.github.gycrosskit.media:media-core-cinterop-imageThumbnail"
    if (manifests[1].get("interop") != "true" or manifests[1].get("depends") != "stdlib"
            or manifests[1].get("unique_name", "").replace("\\:", ":") != unique_name
            or manifests[0].get("unique_name", "").replace("\\:", ":") != "com.github.gycrosskit.media:media-core"
            or unique_name not in manifests[0].get("depends", "").replace("\\:", ":").split()
            or any(item.get("native_targets") != "ohos_arm64" for item in manifests)
            or not manifests[0].get("compiler_version")
            or manifests[0]["compiler_version"] != manifests[1].get("compiler_version")):
        raise ValueError("Media imageThumbnail KLIB dependency/ABI contract changed")
    stdlib, = (item for item in variant["dependencies"]
               if item["group"] == "org.jetbrains.kotlin" and item["module"] == "kotlin-stdlib")
    artifact = "media-cinterop-ohosarm64"
    dependency = {"group": group, "module": artifact, "version": {"requires": version}}
    if any(item.get("module") == artifact for item in variant["dependencies"]):
        raise ValueError("Media cinterop publication already exists")
    target = module.parent.parent.parent / artifact / version
    if target.exists() or target.is_symlink():
        raise ValueError("Media cinterop publication already exists")
    filename = f"{artifact}-{version}.klib"
    namespace = "http://maven.apache.org/POM/4.0.0"
    ET.register_namespace("", namespace)
    q = lambda name: "{" + namespace + "}" + name
    parent = ET.fromstring(module.with_suffix(".pom").read_bytes())
    if (parent.findtext(q("groupId")), parent.findtext(q("artifactId")), parent.findtext(q("version"))) != (
            group, "media-core-ohosarm64", version):
        raise ValueError("Media POM identity mismatch")
    dependencies = parent.find(q("dependencies"))
    if dependencies is None or parent.find(q("licenses")) is None:
        raise ValueError("Media POM dependencies/licenses missing")
    entry = ET.SubElement(dependencies, q("dependency"))
    for key, value in (("groupId", group), ("artifactId", artifact), ("version", version), ("scope", "compile")):
        ET.SubElement(entry, q(key)).text = value
    interop_pom = ET.fromstring(ET.tostring(parent))
    interop_pom.find(q("artifactId")).text = artifact
    interop_dependencies = interop_pom.find(q("dependencies"))
    for entry in list(interop_dependencies):
        interop_dependencies.remove(entry)
    entry = ET.SubElement(interop_dependencies, q("dependency"))
    for key, value in (("groupId", stdlib["group"]), ("artifactId", stdlib["module"]),
                       ("version", stdlib["version"]["requires"]), ("scope", "compile")):
        ET.SubElement(entry, q(key)).text = value
    marker = b"<!-- do_not_remove: published-with-gradle-metadata -->\n"
    published = {"formatVersion": "1.1", "component": {"group": group, "module": artifact, "version": version},
                 "variants": [{"name": variant["name"], "attributes": variant["attributes"],
                               "dependencies": [stdlib], "files": [dict(interop, name=filename, url=filename)]}]}
    outputs = {target / filename: payloads[1], target / f"{artifact}-{version}.module":
               (json.dumps(published, indent=2) + "\n").encode(), target / f"{artifact}-{version}.pom":
               marker + ET.tostring(interop_pom), module.with_suffix(".pom"): marker + ET.tostring(parent)}
    variant["files"].remove(interop)
    variant["dependencies"].append(dependency)
    source = module.parent / interop["url"]
    return target, outputs, [source, *(source.with_name(source.name + "." + algorithm) for algorithm in ALGORITHMS)]


def normalize(files):
    modules = {file.resolve(): json.loads(file.read_text()) for file in files}
    removed = {file: set() for file in modules}
    # 先完成全部验证，非空资源失败时不留下部分改写的仓库。
    for file, data in modules.items():
        for variant in data["variants"]:
            name = variant["name"]
            if name == "metadataSourcesElements" or name.endswith(("SourcesElements-published", "MetadataElements-published")):
                removed[file].add(name)
            elif name.endswith("ResourcesElements-published") and "available-at" not in variant:
                entries = variant.get("files", [])
                if not entries:
                    raise ValueError(f"Resource variant has no archive: {file}: {name}")
                for entry in entries:
                    archive = (file.parent / entry["url"]).resolve()
                    if archive.suffix != ".zip":
                        raise ValueError(f"Unsupported resource archive: {archive}")
                    with ZipFile(archive) as zipped:
                        if any(not item.is_dir() for item in zipped.infolist()):
                            raise ValueError(f"Nonempty resources require a classifier-safe publication: {archive}")
                removed[file].add(name)
    for file, data in modules.items():
        for variant in data["variants"]:
            redirect = variant.get("available-at")
            if redirect and variant["name"].endswith("ResourcesElements-published"):
                target = (file.parent / redirect["url"]).resolve()
                if target not in modules:
                    raise ValueError(f"Missing resource metadata target: {target}")
                if variant["name"] in removed[target]:
                    removed[file].add(variant["name"])
    # 先验证全部输入；错误的真实 interop 不得被裁剪成看似可发布的主 KLIB。
    publications = {file: result for file, data in modules.items()
                    if (result := image_thumbnail_publication(file, data)) is not None}
    for target, outputs, obsolete in publications.values():
        target.mkdir(parents=True, exist_ok=False)
        for path, content in outputs.items():
            path.write_bytes(content)
            for algorithm in ALGORITHMS:
                path.with_name(path.name + "." + algorithm).write_text(hashlib.new(algorithm, content).hexdigest())
        # 只移动私有 staging 的发布位置，KLIB 字节/unique_name 不变，历史归档不改。
        for path in obsolete:
            path.unlink()
    changed = 0
    for file, data in modules.items():
        if removed[file] or file in publications:
            data["variants"] = [variant for variant in data["variants"] if variant["name"] not in removed[file]]
            file.write_text(json.dumps(data, indent=2))
            changed += 1
        for algorithm in ("sha1", "sha256", "sha512", "md5"):
            checksum = file.with_name(file.name + "." + algorithm)
            if checksum.exists():
                checksum.write_text(hashlib.new(algorithm, file.read_bytes()).hexdigest())
    return changed


if __name__ == "__main__":
    roots = list(map(Path, sys.argv[1:])) or [Path.home() / ".m2/repository/com/github/gycrosskit"]
    files = sorted({file for root in roots for file in root.rglob("*.module")})
    if not files:
        raise SystemExit("No Maven module metadata found")
    changed = normalize(files)
    print(f"Checked {len(files)} Maven modules; fixed {changed} JitPack metadata variants")
