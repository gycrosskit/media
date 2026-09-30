import json
import sys
from pathlib import Path

# JitPack rewrites classified source/metadata JAR URLs to missing plain JARs.
if len(sys.argv) > 1:
    files = [file for root in map(Path, sys.argv[1:]) for file in root.rglob("*.module")]
else:
    files = list((Path.home() / ".m2/repository/com/github/gycrosskit").rglob("*.module"))
    files += list(Path.cwd().glob("*/build/publications/**/module.json"))
changed = 0
for file in files:
    data = json.loads(file.read_text())
    variants = [
        variant for variant in data["variants"]
        if not variant["name"].endswith(("SourcesElements-published", "MetadataElements-published"))
    ]
    if len(variants) != len(data["variants"]):
        data["variants"] = variants
        file.write_text(json.dumps(data, indent=2))
        changed += 1
if not changed:
    raise SystemExit("No JitPack KMP metadata variants were fixed")
