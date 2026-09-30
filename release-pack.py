import json
import sys
import tarfile
from pathlib import Path

repository, output, version = map(Path, sys.argv[1:])
# Python tarfile 不写 macOS 扩展属性；只发布当前版本，避免携带旧 staging。
def plain_file(info):
    return None if Path(info.name).name.startswith("._") else info

with tarfile.open(output, "w:gz") as archive:
    directories = list(repository.glob("com/github/gycrosskit/*/*/" + str(version)))
    assert directories, "No Maven publications for this version"
    for directory in directories:
        archive.add(directory, arcname=str(directory.relative_to(repository)), filter=plain_file)
with tarfile.open(output) as archive:
    for member in archive.getmembers():
        assert not Path(member.name).name.startswith("._"), member.name
        if member.name.endswith(".module"):
            json.load(archive.extractfile(member))
