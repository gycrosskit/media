#!/usr/bin/env python3
"""保存子进程日志，只终止有明确字节证据的 Native 下载停滞，不重试构建或测试。"""
import argparse
import json
import os
import re
import selectors
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

PROGRESS = re.compile(r'Downloading dependency for Kotlin Native: (\S+) \((\d+)/(\d+)\)')


class Downloads:
    def __init__(self):
        self.active = {}

    def observe(self, line, now):
        match = PROGRESS.search(line)
        if match:
            url, current, total = match.group(1), int(match.group(2)), int(match.group(3))
            if total > 0 and current >= total:
                self.active.pop(url, None)
            elif total > 0:
                previous = self.active.get(url)
                if previous is None or previous['bytes'] != current or previous['total'] != total:
                    self.active[url] = {'bytes': current, 'total': total, 'progress_at': now}
        elif re.search(r'(?:^|\s)> Task |Extracting dependency|Unpacking |BUILD (?:SUCCESSFUL|FAILED)', line):
            # Native 下载是同步阶段，进入解包/下一编译 task 后不能把旧进度当成仍在下载。
            self.active.clear()

    def stalled(self, now, seconds):
        return [dict(url=url, **state) for url, state in self.active.items()
                if now - state['progress_at'] >= seconds]


def stop(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait()
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    # leader 退出不能证明同组 Gradle/编译子进程已退出。
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run(command, log_path, no_progress_seconds):
    log_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    started_at = datetime.now(timezone.utc).isoformat()
    downloads, pending, stalled = Downloads(), b'', []
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        with log_path.open('ab') as log, selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                for key, _ in selector.select(timeout=0.2):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    log.write(chunk)
                    log.flush()
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                    lines = re.split(b'[\r\n]', pending + chunk)
                    pending = lines.pop()[-65536:]
                    for line in lines:
                        downloads.observe(line.decode('utf-8', errors='replace'), time.monotonic())
                stalled = downloads.stalled(time.monotonic(), no_progress_seconds)
                if stalled:
                    detail = ('Native download made no byte progress for %s seconds; stopping without retry\n' % no_progress_seconds).encode()
                    log.write(detail)
                    sys.stderr.write(detail.decode())
                    stop(process)
                    break
            exit_code = 124 if stalled else process.wait()
    except BaseException:
        stop(process)
        raise
    finally:
        process.stdout.close()
    receipt = {'command': command, 'started_at': started_at, 'finished_at': datetime.now(timezone.utc).isoformat(),
               'exit_code': exit_code, 'elapsed_seconds': round(time.monotonic() - started, 3),
               'download_stall': stalled, 'automatic_build_retry': False}
    with log_path.with_suffix(log_path.suffix + '.jsonl').open('a') as receipts:
        receipts.write(json.dumps(receipt) + '\n')
    return exit_code if exit_code >= 0 else 128 - exit_code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', required=True, type=Path)
    parser.add_argument('--no-progress-seconds', type=float, default=300)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or args.no_progress_seconds <= 0:
        parser.error('Provide a command and a positive no-progress timeout')
    sys.exit(run(command, args.log, args.no_progress_seconds))


if __name__ == '__main__':
    main()
