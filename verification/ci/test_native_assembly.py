"""真实执行装配shell的参数边界；Gradle/SDK命令用记录替身，不编译或发布。"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/verify-kuikly-assembly.sh'


class NativeAssemblyTest(unittest.TestCase):
    def run_script(self, version=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            script = root / 'scripts/verify-kuikly-assembly.sh'
            script.write_text(SCRIPT.read_text())
            calls = root / 'calls.json'
            capture = """import json,os,sys
from pathlib import Path
p=Path(os.environ['ASSEMBLY_CALLS'])
v=json.loads(p.read_text()) if p.exists() else []
v.append(dict(kind=KIND,args=sys.argv[1:],version=os.environ.get('VERSION')))
p.write_text(json.dumps(v))
"""
            (root / 'gradlew').write_text(shlex.quote(sys.executable) + " - \"$@\" <<'CAPTURE'\n" +
                                         "KIND='gradle'\n" + capture + 'CAPTURE\n')
            tools = root / 'tools'; tools.mkdir()
            (tools / 'uname').write_text('#!/bin/sh\nprintf \"arm64\\n\"\n')
            (tools / 'xcrun').write_text('#!' + sys.executable + '\nKIND=\"xcrun\"\n' + capture +
                                      "if sys.argv[1:3]==['--sdk','iphonesimulator']:print('/fixture/sdk')\n")
            for tool in tools.iterdir(): tool.chmod(0o755)
            command = ['bash', str(script), str(root / 'Products')]
            if version is not None: command.append(version)
            result = subprocess.run(command, env=dict(os.environ, PATH=str(tools)+os.pathsep+os.environ['PATH'],
                VERSION='9.9.9', ASSEMBLY_CALLS=str(calls)), capture_output=True, text=True)
            return result, json.loads(calls.read_text()) if calls.exists() else []

    def test_missing_exact_version_rejects_before_any_sdk_or_gradle(self):
        result, calls = self.run_script()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('exact source Maven version', result.stderr)
        self.assertEqual([], calls)

    def test_producer_and_consumer_bind_same_explicit_version(self):
        result, calls = self.run_script('7.8.9')
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        builds = [c for c in calls if c['kind']=='gradle']
        self.assertEqual(2, len(builds))
        self.assertTrue(all(c['version']=='7.8.9' for c in builds))
        self.assertIn('-PmediaVersion=7.8.9', builds[1]['args'])
        self.assertTrue(any(a.startswith('-PmediaMavenRepo=') for a in builds[1]['args']))
        self.assertEqual('swiftc', calls[-1]['args'][0])
        self.assertIn('verification-consumer/NativeModuleAssembly.swift', calls[-1]['args'])


if __name__ == '__main__': unittest.main()
