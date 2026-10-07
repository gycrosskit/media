#!/usr/bin/env python3
"""CI 单用途 DNS helper 的信任边界；curl/sudo 全部替身，绝不写真实 hosts。"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/ci-pin-fork-host.sh'
HOST = 'maven.eazytec-cloud.com'
ADDRESS = '61.177.127.227'
ANSWER = {'Status': 0, 'Question': [{'name': HOST + '.', 'type': 1}],
          'Answer': [{'name': HOST + '.', 'type': 1, 'data': ADDRESS}]}

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    (root / 'curl').write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
assert args[0] == '--disable' and '--ipv4' in args
assert args[args.index('--proto') + 1] == '=https'
assert args[args.index('--noproxy') + 1] == 'maven.eazytec-cloud.com,cloudflare-dns.com'
assert not any(option in args for option in ['-k', '--insecure', '-L', '--location'])
url = args[-1]
with open(os.environ['MOCK_CALLS'], 'a') as calls:
    calls.write(url + '\\n')
if url.startswith('https://cloudflare-dns.com/'):
    assert url == 'https://cloudflare-dns.com/dns-query?name=maven.eazytec-cloud.com&type=A'
    assert args[args.index('--header') + 1] == 'Accept: application/dns-json'
    Path(args[args.index('--output') + 1]).write_text(os.environ['MOCK_ANSWER'])
    print('200', end='')
elif '--resolve' in args:
    assert args[args.index('--resolve') + 1] == 'maven.eazytec-cloud.com:443:61.177.127.227'
    if os.environ['MOCK_CASE'] == 'doh_tls':
        sys.exit(35)
    print('200 ' + ('8.8.8.8' if os.environ['MOCK_CASE'] == 'doh_mismatch' else '61.177.127.227'), end='')
else:
    assert url.startswith('https://maven.eazytec-cloud.com/') and url.endswith('.pom')
    case = os.environ['MOCK_CASE']
    if case.startswith('doh_'):
        sys.exit(6)
    if case in ['tls', 'http']:
        sys.exit(35 if case == 'tls' else 22)
    print('200 ' + ('127.0.0.1' if case == 'private' else '61.177.127.227'), end='')
''')
    (root / 'sudo').write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
assert sys.argv[1:] == ['tee', '-a', '/etc/hosts']
if os.environ['MOCK_CASE'] == 'write_failure':
    sys.exit(1)
Path(os.environ['MOCK_HOSTS']).write_text(sys.stdin.read())
''')
    (root / 'sleep').write_text('#!/usr/bin/env bash\nexit 0\n')
    for name in ['curl', 'sudo', 'sleep']:
        (root / name).chmod(0o755)
    environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       GITHUB_ACTIONS='true', RUNNER_ENVIRONMENT='github-hosted', RUNNER_OS='Linux',
                       MOCK_HOSTS=str(root / 'hosts'), MOCK_CALLS=str(root / 'calls'))
    cases = ['outside_ci', 'self_hosted', 'normal', 'write_failure', 'private', 'tls', 'http',
             'doh_bad_status', 'doh_wrong_question', 'doh_wrong_owner', 'doh_private', 'doh_tls', 'doh_mismatch', 'doh_valid']
    for case in cases:
        answer = json.loads(json.dumps(ANSWER))
        if case == 'doh_bad_status':
            answer['Status'] = 3
        if case == 'doh_wrong_question':
            answer['Question'][0]['name'] = 'other.example.'
        if case == 'doh_wrong_owner':
            answer['Answer'][0]['name'] = 'other.example.'
        if case == 'doh_private':
            answer['Answer'][0]['data'] = '127.0.0.1'
        environment.update(MOCK_CASE=case, MOCK_ANSWER=json.dumps(answer),
                           GITHUB_ACTIONS='false' if case == 'outside_ci' else 'true',
                           RUNNER_ENVIRONMENT='self-hosted' if case == 'self_hosted' else 'github-hosted')
        for name in ['hosts', 'calls']:
            (root / name).unlink(missing_ok=True)
        result = subprocess.run(['bash', str(SCRIPT)], env=environment, capture_output=True, text=True)
        assert result.returncode == 0, (case, result.stderr)
        pinned = case in ['normal', 'doh_valid']
        assert (root / 'hosts').exists() == pinned, case
        assert ('job host address reused' in result.stdout) == pinned, case
        if pinned:
            assert (root / 'hosts').read_text() == ADDRESS + ' ' + HOST + '\n'
        calls = (root / 'calls').read_text() if (root / 'calls').exists() else ''
        assert ('cloudflare-dns.com' in calls) == case.startswith('doh_'), case
        if case in ['outside_ci', 'self_hosted']:
            assert not calls, case
    print(f'fork host trust boundaries: {len(cases)} cases passed (all hosts writes mocked)')
