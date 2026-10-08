import ipaddress
import json
from pathlib import Path
import socket
import subprocess

HOST = 'maven.eazytec-cloud.com'
URL = f'https://{HOST}/nexus/repository/maven-public/org/jetbrains/kotlin/multiplatform/org.jetbrains.kotlin.multiplatform.gradle.plugin/2.2.21-1.0.0/org.jetbrains.kotlin.multiplatform.gradle.plugin-2.2.21-1.0.0.pom'
OUT = Path('network-proof')
OUT.mkdir(exist_ok=True)
addresses = set()
try:
    answers = sorted({a[4][0] for a in socket.getaddrinfo(HOST, 443, socket.AF_INET)})
    print('System DNS:', answers, flush=True)
    addresses.update(answers)
except OSError as error:
    print('System DNS error:', repr(error), flush=True)

def request(label, url, extra=()):
    command = ['curl', '--disable', '--silent', '--show-error', '--proto', '=https', '--ipv4',
               '--noproxy', '*', '--connect-timeout', '10', '--max-time', '20',
               '--dump-header', str(OUT / (label + '.headers')),
               '--output', str(OUT / (label + '.body')),
               '--write-out', '%{http_code} %{remote_ip} connect=%{time_connect} tls=%{time_appconnect} total=%{time_total}',
               *extra, url]
    result = subprocess.run(command, capture_output=True, text=True, timeout=25)
    record = {'label': label, 'exit': result.returncode, 'response': result.stdout, 'error': result.stderr}
    print(json.dumps(record), flush=True)
    (OUT / (label + '.json')).write_text(json.dumps(record, indent=2))
    return result.returncode

request('system-marker', URL)
for label, url in [('cloudflare', f'https://cloudflare-dns.com/dns-query?name={HOST}&type=A'),
                   ('google', f'https://dns.google/resolve?name={HOST}&type=A'),
                   ('alidns', f'https://dns.alidns.com/resolve?name={HOST}&type=A')]:
    if request(label, url, ('--header', 'Accept: application/dns-json')) == 0:
        try:
            response = json.loads((OUT / (label + '.body')).read_text())
            records = [a['data'] for a in response.get('Answer', []) if a.get('type') == 1]
            print(label, 'DNS:', records, flush=True)
            addresses.update(records)
        except (ValueError, KeyError) as error:
            print(label, 'parse error:', repr(error), flush=True)
# 仅诊断此前真实 HTTPS 成功日志中的地址；生产恢复不直接采用历史地址。
addresses.update(['61.177.127.227', '36.153.109.99'])
for address in sorted(addresses):
    parsed = ipaddress.IPv4Address(address)
    if parsed.is_global and not parsed.is_multicast:
        request('resolved-' + address, URL, ('--resolve', f'{HOST}:443:{address}'))
