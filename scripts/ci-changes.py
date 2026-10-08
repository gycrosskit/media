#!/usr/bin/env python3
"""PR 仅跳过已知纯文档变化；无法确定范围时保守执行源码验证。"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath


def documentation(path):
    parts = PurePosixPath(path).parts
    return (len(parts) == 1 and path in ('README.md', 'AGENTS.md', 'CHANGELOG.md')) or (
        len(parts) > 1 and parts[0] in ('docs', 'skills') and path.endswith('.md'))


def source_needed(event_name, event, changed_paths=None):
    if event_name in ('push', 'release'):
        return False
    if event_name == 'workflow_dispatch':
        return not event.get('inputs', {}).get('version')
    if event_name != 'pull_request' or changed_paths is None:
        return True
    return any(not documentation(path) for path in changed_paths)


def main():
    event_name = os.environ.get('GITHUB_EVENT_NAME', '')
    try:
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        paths = None
        if event_name == 'pull_request':
            pull = event['pull_request']
            base, head = pull['base']['sha'], pull['head']['sha']
            if not all(re.fullmatch(r'[0-9a-f]{40}', sha) for sha in (base, head)):
                raise ValueError('Invalid PR commit')
            common = subprocess.check_output(['git', 'merge-base', base, head], text=True).strip()
            # 禁用 rename 合并，文档改名为源码时必须同时检查新旧路径。
            raw = subprocess.check_output(['git', 'diff', '--no-renames', '--name-only', '-z', common, head])
            paths = [path.decode('utf-8') for path in raw.split(b'\0') if path]
        needed = source_needed(event_name, event, paths)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print('Cannot determine change scope; running source checks: ' + str(error), file=sys.stderr)
        needed = True
    result = 'source=' + str(needed).lower() + '\n'
    sys.stdout.write(result)
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(result)


if __name__ == '__main__':
    main()
