#!/usr/bin/env python3
"""Picker 失败取证保留真实退出码和 PASS 门禁，不依赖本机 Xcode。"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
for launch_exit, output, expected in [(0, 'PASS: Picker ownership', 0), (7, 'START', 7), (0, 'START', 1)]:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        (root / 'scripts').mkdir()
        shutil.copyfile(ROOT / 'scripts/verify-ios-picker.sh', root / 'scripts/verify-ios-picker.sh')
        tools = root / 'tools'
        tools.mkdir()
        commands = {'codesign': '#!/bin/bash\nexit 0\n', 'xcrun': r'''#!/bin/bash
if [[ "$*" == *--show-sdk-path* ]]; then echo /fake-sdk
elif [[ "$1 $2" == 'simctl launch' ]]; then
    printf '%s\n' "$PICKER_TEST_OUTPUT"
    echo fixture-stderr >&2
    exit "$PICKER_TEST_EXIT"
elif [[ "$1 $2" == 'simctl spawn' ]]; then echo fixture-simulator-log
fi
'''}
        for name, content in commands.items():
            file = tools / name
            file.write_text(content)
            file.chmod(0o755)
        reports = root / 'home/Library/Logs/DiagnosticReports'
        reports.mkdir(parents=True)
        (reports / 'PickerCheck-fixture.ips').write_text('fixture-crash')
        (reports / 'Unrelated.ips').write_text('must-not-copy')
        (reports / 'PickerCheckOther-fixture.ips').write_text('must-not-copy')
        env = dict(os.environ, HOME=str(root / 'home'), PATH=str(tools) + os.pathsep + os.environ['PATH'],
                   PICKER_TEST_OUTPUT=output, PICKER_TEST_EXIT=str(launch_exit), MEDIA_SIMULATOR='fixture')
        result = subprocess.run(['bash', 'scripts/verify-ios-picker.sh'], cwd=root, env=env, capture_output=True, text=True)
        assert result.returncode == expected, (launch_exit, result.stdout, result.stderr)
        assert 'fixture-stderr' in (root / 'build/ios-picker-check/result.log').read_text()
        if expected:
            assert (root / 'ci-diagnostics/PickerCheck-fixture.ips.txt').read_text() == 'fixture-crash'
            assert 'fixture-simulator-log' in (root / 'ci-diagnostics/picker-simulator.txt').read_text()
            assert not list((root / 'ci-diagnostics').glob('Unrelated*'))
            assert not list((root / 'ci-diagnostics').glob('PickerCheckOther*'))
        else:
            assert not (root / 'ci-diagnostics').exists()
print('Picker harness: success marker, launch failure, missing marker and isolated diagnostics passed')
